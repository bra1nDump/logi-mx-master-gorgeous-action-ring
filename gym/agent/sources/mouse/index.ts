import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, mkdtemp, rm, stat } from "node:fs/promises";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const defaultPackagePath = fileURLToPath(new URL("../../../../", import.meta.url));
const maximumCapturedBytes = 1024 * 1024;

export interface MouseControlError {
  code: string;
  data: unknown;
  message: string;
}

export interface MouseControlResponse<Result = unknown> {
  error: MouseControlError | null;
  requestID: string;
  result: Result;
  schemaVersion: number;
}

export interface MouseControlEvent<Payload = unknown> {
  event: string;
  payload: Payload;
  requestID: string;
  schemaVersion: number;
}

export interface MouseCLIResult<Result = unknown> {
  exitCode: number;
  response?: MouseControlResponse<Result>;
  stderr: string;
  stdout: string;
}

export interface NativeMouseGymOptions {
  /** Skip the Swift build only when the caller supplies already-built executables. */
  build?: boolean;
  cliPath?: string;
  fixturePath?: string;
  packagePath?: string;
  startupTimeoutMs?: number;
}

/**
 * A black-box native mouse backend fixture. It runs the production control and
 * runtime boundaries with fake HID/action adapters, on a real private Unix
 * socket, and drives it exclusively through the native CLI.
 */
export class NativeMouseGym implements AsyncDisposable {
  readonly configPath: string;
  readonly directory: string;
  readonly socketPath: string;

  private daemon: ChildProcessWithoutNullStreams | undefined;
  private daemonError: Error | undefined;
  private daemonExit: { code: number | null; signal: NodeJS.Signals | null } | undefined;
  private daemonStderr = "";
  private daemonStdout = "";

  private constructor(
    directory: string,
    private readonly cliPath: string,
    private readonly fixturePath: string,
  ) {
    this.directory = directory;
    this.configPath = join(directory, "config.json");
    this.socketPath = join(directory, "control.sock");
  }

  static async create(options: NativeMouseGymOptions = {}): Promise<NativeMouseGym> {
    if (process.platform !== "darwin")
      throw new Error("The native mouse gym is only available on macOS");

    const packagePath = options.packagePath ?? defaultPackagePath;
    const products = await resolveProducts({
      build: options.build ?? (options.cliPath === undefined || options.fixturePath === undefined),
      cliPath: options.cliPath,
      fixturePath: options.fixturePath,
      packagePath,
    });

    // Keep this deliberately short: sockaddr_un.sun_path is only 104 bytes on macOS.
    const directory = await mkdtemp("/tmp/logi-liquid-gym-");
    const gym = new NativeMouseGym(directory, products.cliPath, products.fixturePath);
    try {
      await gym.startDaemon(options.startupTimeoutMs ?? 15_000);
      return gym;
    } catch (error) {
      await gym.close();
      throw error;
    }
  }

  get capturedDaemonStderr(): string {
    return this.daemonStderr;
  }

  get capturedDaemonStdout(): string {
    return this.daemonStdout;
  }

  async cli<Result = unknown>(arguments_: readonly string[]): Promise<MouseCLIResult<Result>> {
    const result = await runProcess(
      this.cliPath,
      ["--socket", this.socketPath, ...arguments_],
      10_000,
    );
    const stdout = result.stdout.trim();
    let response: MouseControlResponse<Result> | undefined;
    if (stdout !== "") {
      try {
        response = JSON.parse(stdout) as MouseControlResponse<Result>;
      } catch {
        // Usage and transport failures may intentionally be diagnostics-only.
      }
    }
    return { ...result, response };
  }

  async request<Result = unknown>(
    arguments_: readonly string[],
  ): Promise<MouseControlResponse<Result>> {
    const result = await this.cli<Result>(arguments_);
    if (result.exitCode !== 0 || result.response === undefined || result.response.error !== null) {
      throw new Error(
        `Mouse CLI request failed (${result.exitCode}): ${result.stdout || result.stderr}`,
      );
    }
    return result.response;
  }

  async follow(arguments_: readonly [string, string]): Promise<MouseCLIEventStream> {
    return MouseCLIEventStream.open(this.cliPath, this.socketPath, arguments_);
  }

  async socketMode(): Promise<number> {
    return (await stat(this.socketPath)).mode & 0o777;
  }

  async directoryMode(): Promise<number> {
    return (await stat(this.directory)).mode & 0o777;
  }

  async stopDaemon(): Promise<void> {
    const daemon = this.daemon;
    if (daemon === undefined) return;
    this.daemon = undefined;

    await terminate(daemon, 5_000);
    await waitUntil(async () => !(await pathExists(this.socketPath)), 2_000);
  }

  async close(): Promise<void> {
    await this.stopDaemon();
    await rm(this.directory, { force: true, recursive: true });
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  private async startDaemon(startupTimeoutMs: number): Promise<void> {
    const daemon = spawn(
      this.fixturePath,
      ["--foreground", "--socket", this.socketPath, "--config", this.configPath],
      { stdio: ["pipe", "pipe", "pipe"] },
    );
    daemon.stdin.end();
    this.daemon = daemon;
    daemon.stdout.on("data", (chunk: Buffer) => {
      this.daemonStdout = appendBounded(this.daemonStdout, chunk);
    });
    daemon.stderr.on("data", (chunk: Buffer) => {
      this.daemonStderr = appendBounded(this.daemonStderr, chunk);
    });
    daemon.once("error", (error) => {
      this.daemonError = error;
    });
    daemon.once("exit", (code, signal) => {
      this.daemonExit = { code, signal };
    });

    await waitUntil(async () => {
      if (this.daemonError !== undefined) throw this.daemonError;
      if (this.daemonExit !== undefined)
        throw new Error(
          `Mouse daemon exited before readiness (${String(this.daemonExit.code)}/${String(
            this.daemonExit.signal,
          )}): ${this.daemonStderr}`,
        );
      if (!(await pathExists(this.socketPath))) return false;
      const status = await this.cli(["status"]);
      return status.exitCode === 0 && status.response?.error === null;
    }, startupTimeoutMs);
  }
}

export async function createNativeMouseGym(
  options: NativeMouseGymOptions = {},
): Promise<NativeMouseGym> {
  return NativeMouseGym.create(options);
}

export class MouseCLIEventStream implements AsyncDisposable {
  readonly stderrChunks: string[] = [];

  private readonly lines: string[] = [];
  private readonly waiters: Array<() => void> = [];
  private exit: { code: number | null; signal: NodeJS.Signals | null } | undefined;

  private constructor(private readonly child: ChildProcessWithoutNullStreams) {
    const lines = createInterface({ input: child.stdout });
    lines.on("line", (line) => {
      this.lines.push(line);
      this.waiters.shift()?.();
    });
    child.stderr.on("data", (chunk: Buffer) => this.stderrChunks.push(chunk.toString("utf8")));
    child.once("exit", (code, signal) => {
      this.exit = { code, signal };
      while (this.waiters.length > 0) this.waiters.shift()?.();
    });
  }

  static async open(
    cliPath: string,
    socketPath: string,
    arguments_: readonly [string, string],
  ): Promise<MouseCLIEventStream> {
    const child = spawn(cliPath, ["--socket", socketPath, ...arguments_], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    child.stdin.end();
    const stream = new MouseCLIEventStream(child);
    await Promise.race([
      new Promise<void>((resolve, reject) => {
        child.once("spawn", resolve);
        child.once("error", reject);
      }),
      timeout(2_000, "Mouse CLI stream did not start"),
    ]);
    // The CLI intentionally suppresses the wire acknowledgement. Give it one
    // scheduler turn to register the subscription before the test mutates state.
    await new Promise<void>((resolve) => setTimeout(resolve, 100));
    return stream;
  }

  async next<Payload = unknown>(timeoutMs = 2_000): Promise<MouseControlEvent<Payload>> {
    while (this.lines.length === 0) {
      if (this.exit !== undefined)
        throw new Error(
          `Mouse CLI stream exited (${String(this.exit.code)}/${String(this.exit.signal)}): ${this.stderrChunks.join("")}`,
        );
      let wake!: () => void;
      const lineAvailable = new Promise<void>((resolve) => {
        wake = resolve;
        this.waiters.push(wake);
      });
      try {
        await Promise.race([
          lineAvailable,
          timeout(timeoutMs, "Timed out waiting for mouse control event"),
        ]);
      } finally {
        const index = this.waiters.indexOf(wake);
        if (index >= 0) this.waiters.splice(index, 1);
      }
    }

    const line = this.lines.shift()!;
    return JSON.parse(line) as MouseControlEvent<Payload>;
  }

  async close(): Promise<void> {
    await terminate(this.child, 2_000);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }
}

interface ProductResolutionOptions {
  build: boolean;
  cliPath?: string;
  fixturePath?: string;
  packagePath: string;
}

async function resolveProducts(options: ProductResolutionOptions): Promise<{
  cliPath: string;
  fixturePath: string;
}> {
  if (options.cliPath !== undefined && options.fixturePath !== undefined) {
    await Promise.all([requireExecutable(options.cliPath), requireExecutable(options.fixturePath)]);
    return { cliPath: options.cliPath, fixturePath: options.fixturePath };
  }

  if (options.build) {
    const build = await runProcess(
      "swift",
      ["build", "--package-path", options.packagePath],
      120_000,
    );
    if (build.exitCode !== 0)
      throw new Error(`Could not build native mouse products: ${build.stderr || build.stdout}`);
  }

  const binPath = await runProcess(
    "swift",
    ["build", "--package-path", options.packagePath, "--show-bin-path"],
    30_000,
  );
  if (binPath.exitCode !== 0)
    throw new Error(`Could not resolve native mouse products: ${binPath.stderr || binPath.stdout}`);

  const cliPath = options.cliPath ?? join(binPath.stdout.trim(), "logi-liquid");
  const fixturePath =
    options.fixturePath ?? join(binPath.stdout.trim(), "logi-liquid-daemon-fixture");
  await Promise.all([requireExecutable(cliPath), requireExecutable(fixturePath)]);
  return { cliPath, fixturePath };
}

async function requireExecutable(path: string): Promise<void> {
  await access(path, fsConstants.X_OK);
}

async function runProcess(
  executable: string,
  arguments_: readonly string[],
  timeoutMs: number,
): Promise<{ exitCode: number; stderr: string; stdout: string }> {
  const child = spawn(executable, arguments_, { stdio: ["pipe", "pipe", "pipe"] });
  child.stdin.end();
  let stderr = "";
  let stdout = "";
  child.stdout.on("data", (chunk: Buffer) => {
    stdout = appendBounded(stdout, chunk);
  });
  child.stderr.on("data", (chunk: Buffer) => {
    stderr = appendBounded(stderr, chunk);
  });

  return new Promise<{ exitCode: number; stderr: string; stdout: string }>((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${executable} timed out`));
    }, timeoutMs);
    timer.unref();
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      resolve({
        exitCode: code ?? (signal === null ? 1 : 128),
        stderr,
        stdout,
      });
    });
  });
}

async function waitForExit(child: ChildProcessWithoutNullStreams): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  await new Promise<void>((resolve) => child.once("exit", () => resolve()));
}

async function terminate(child: ChildProcessWithoutNullStreams, graceMs: number): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  const exited = await Promise.race([
    waitForExit(child).then(() => true),
    new Promise<false>((resolve) => {
      setTimeout(() => resolve(false), graceMs).unref();
    }),
  ]);
  if (exited) return;
  child.kill("SIGKILL");
  await waitForExit(child);
}

async function waitUntil(predicate: () => Promise<boolean>, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await predicate())) {
    if (Date.now() >= deadline) throw new Error(`Condition was not met within ${timeoutMs} ms`);
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function appendBounded(previous: string, chunk: Buffer): string {
  const next = previous + chunk.toString("utf8");
  return next.length <= maximumCapturedBytes ? next : next.slice(-maximumCapturedBytes);
}

function timeout(milliseconds: number, message: string): Promise<never> {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error(message)), milliseconds).unref();
  });
}

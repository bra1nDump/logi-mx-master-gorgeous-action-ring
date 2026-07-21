import { readFile, stat } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { createNativeMouseGym } from "../../../sources/mouse/index.js";

type CardinalZone = "bottom" | "left" | "right" | "top";

interface RingZones {
  bottom: string[];
  left: string[];
  right: string[];
  top: string[];
}

interface MouseConfiguration {
  actions: Record<string, unknown>;
  applicationSpecific: Record<string, { bottom: string[] }>;
  version: number;
  zones: RingZones;
}

interface ResolvedMouseConfiguration {
  actions: Record<string, unknown>;
  context: { bundleID: string | null; localizedName: string | null };
  zones: RingZones;
}

interface RingTransition {
  actionToPerform: { name: string; zone: CardinalZone } | null;
  cursorVisibilityIntent: "hide" | "none" | "restore";
  frame: {
    currentTarget: { actionName: string; zone: CardinalZone } | null;
    approachProgress: number;
    mergeProgress: number;
    phase: "cancelled" | "committed" | "idle" | "invoked" | "latched" | "tracking";
    targetVectors: Array<{ actionName: string; index: number; zone: CardinalZone }>;
    zoneLayouts: Array<{
      actionNames: string[];
      isPlaceholder: boolean;
      zone: CardinalZone;
    }>;
  };
  hapticIntent: { type: "none" | "play"; waveformID?: number };
}

const emptyZones: RingZones = { bottom: [], left: [], right: [], top: [] };

describe
  .skipIf(process.platform !== "darwin")
  .sequential("native mouse agent control boundary", () => {
    it("configures cardinal quick actions and resolves only bottom for the focused app", async () => {
      await using mouse = await createNativeMouseGym();

      const empty = await mouse.request<MouseConfiguration>(["actions", "list"]);
      expect(empty.result).toEqual({
        actions: {},
        applicationSpecific: {},
        version: 2,
        zones: emptyZones,
      });
      const emptyInvocation = await mouse.request<RingTransition>(["simulate", "invoke", "0", "0"]);
      expect(emptyInvocation.result).toMatchObject({
        actionToPerform: null,
        cursorVisibilityIntent: "none",
        frame: {
          phase: "idle",
          targetVectors: [],
          zoneLayouts: [
            { actionNames: [], isPlaceholder: false, zone: "top" },
            { actionNames: [], isPlaceholder: false, zone: "right" },
            { actionNames: [], isPlaceholder: true, zone: "bottom" },
            { actionNames: [], isPlaceholder: false, zone: "left" },
          ],
        },
        hapticIntent: { type: "none" },
      });

      await mouse.request(["actions", "put-spotify-play", "Play Spotify", "--zone", "top"]);
      await mouse.request([
        "actions",
        "put-application",
        "Telegram",
        "ru.keepcoder.Telegram",
        "--zone",
        "right",
      ]);
      await mouse.request([
        "actions",
        "put-shortcut",
        "ChatGPT Quick Chat",
        "space",
        "--modifiers",
        "option",
        "--zone",
        "right",
      ]);
      await mouse.request([
        "actions",
        "put-shortcut",
        "Aqua Voice",
        "fn",
        "--press-count",
        "2",
        "--zone",
        "left",
      ]);
      await mouse.request([
        "actions",
        "put-url",
        "CleanShot Capture",
        "cleanshot://capture-area",
        "--zone",
        "left",
      ]);
      const configured = await mouse.request<MouseConfiguration>([
        "actions",
        "put-url",
        "CleanShot Record",
        "cleanshot://record-screen",
        "--zone",
        "left",
      ]);

      expect(configured.result.zones).toEqual({
        top: ["Play Spotify"],
        right: ["Telegram", "ChatGPT Quick Chat"],
        bottom: [],
        left: ["Aqua Voice", "CleanShot Capture", "CleanShot Record"],
      });
      expect(configured.result.actions).toMatchObject({
        "Aqua Voice": {
          key: "fn",
          modifiers: [],
          repeatCount: 2,
          type: "shortcut",
        },
        "ChatGPT Quick Chat": {
          key: "space",
          modifiers: ["option"],
          repeatCount: 1,
          type: "shortcut",
        },
        "CleanShot Capture": { type: "url", url: "cleanshot://capture-area" },
        "CleanShot Record": { type: "url", url: "cleanshot://record-screen" },
        "Play Spotify": { playback: "play", type: "spotify" },
        Telegram: { bundleID: "ru.keepcoder.Telegram", type: "application" },
      });

      await mouse.request([
        "actions",
        "put-command",
        "Xcode Build",
        "/usr/bin/true",
        "--zone",
        "bottom",
        "--when-app",
        "com.apple.dt.Xcode",
      ]);
      const xcode = await mouse.request<ResolvedMouseConfiguration>([
        "actions",
        "resolve",
        "--app",
        "com.apple.dt.Xcode",
      ]);
      const finder = await mouse.request<ResolvedMouseConfiguration>([
        "actions",
        "resolve",
        "--app",
        "com.apple.finder",
      ]);
      expect(xcode.result.context.bundleID).toBe("com.apple.dt.Xcode");
      expect(xcode.result.zones.bottom).toEqual(["Xcode Build"]);
      expect(finder.result.zones.bottom).toEqual([]);
      expect(xcode.result.zones.top).toEqual(finder.result.zones.top);
      expect(xcode.result.zones.left).toEqual(finder.result.zones.left);
      expect(xcode.result.zones.right).toEqual(finder.result.zones.right);

      await mouse.request([
        "actions",
        "put-url",
        "CleanShot Record",
        "cleanshot://record-screen",
        "--zone",
        "bottom",
        "--when-app",
        "com.apple.dt.Xcode",
      ]);
      const scopedRemoval = await mouse.request<MouseConfiguration>([
        "actions",
        "remove",
        "CleanShot Record",
        "--zone",
        "bottom",
        "--when-app",
        "com.apple.dt.Xcode",
      ]);
      expect(scopedRemoval.result.applicationSpecific["com.apple.dt.Xcode"]?.bottom).toEqual([
        "Xcode Build",
      ]);
      expect(scopedRemoval.result.actions["CleanShot Record"]).toEqual({
        type: "url",
        url: "cleanshot://record-screen",
      });
      expect(scopedRemoval.result.zones.left).toContain("CleanShot Record");

      const cleared = await mouse.request<MouseConfiguration>([
        "actions",
        "clear",
        "--zone",
        "bottom",
        "--when-app",
        "com.apple.dt.Xcode",
      ]);
      expect(cleared.result.applicationSpecific["com.apple.dt.Xcode"]?.bottom).toEqual([]);
      expect(cleared.result.actions["Xcode Build"]).toBeDefined();
      const clearedXcode = await mouse.request<ResolvedMouseConfiguration>([
        "actions",
        "resolve",
        "--app",
        "com.apple.dt.Xcode",
      ]);
      expect(clearedXcode.result.zones.bottom).toEqual([]);

      const moved = await mouse.request<MouseConfiguration>([
        "actions",
        "move",
        "CleanShot Record",
        "0",
        "--zone",
        "left",
      ]);
      expect(moved.result.zones.left).toEqual([
        "CleanShot Record",
        "Aqua Voice",
        "CleanShot Capture",
      ]);

      const durable = JSON.parse(await readFile(mouse.configPath, "utf8")) as MouseConfiguration;
      expect(durable).toEqual(moved.result);

      const invalidPlacement = await mouse.cli([
        "actions",
        "put-application",
        "Invalid",
        "com.example.Invalid",
        "--zone",
        "right",
        "--when-app",
        "com.apple.dt.Xcode",
      ]);
      expect(invalidPlacement.exitCode).toBe(2);
      expect(invalidPlacement.stderr).toContain("--when-app requires `--zone bottom`");
    }, 120_000);

    it("keeps the ring open on release and supports auto, click, toggle, and explicit dismissal", async () => {
      await using mouse = await createNativeMouseGym();
      await mouse.request(["actions", "put-command", "Top", "/usr/bin/true", "--zone", "top"]);
      await using events = await mouse.follow(["events", "follow"]);

      const invoked = await mouse.request<RingTransition>([
        "simulate",
        "invoke",
        "400",
        "300",
        "--app",
        "com.apple.finder",
      ]);
      expect(invoked.result).toMatchObject({
        actionToPerform: null,
        cursorVisibilityIntent: "hide",
        frame: {
          phase: "invoked",
          targetVectors: [{ actionName: "Top", index: 0, zone: "top" }],
        },
        hapticIntent: { type: "none" },
      });

      const released = await mouse.request<RingTransition>(["simulate", "release"]);
      expect(released.result.frame.phase).toBe("invoked");
      expect(released.result.cursorVisibilityIntent).toBe("none");

      const latched = await mouse.request<RingTransition>(["simulate", "move", "0", "-113"]);
      expect(latched.result.frame.phase).toBe("latched");
      expect(latched.result.frame.mergeProgress).toBe(1);
      expect(latched.result.cursorVisibilityIntent).toBe("none");
      expect(latched.result.actionToPerform).toMatchObject({ name: "Top", zone: "top" });
      expect(latched.result.hapticIntent).toEqual({ type: "play", waveformID: 0 });

      const streamed = await Promise.all([
        events.next<RingTransition>(),
        events.next<RingTransition>(),
        events.next<RingTransition>(),
        events.next(),
        events.next<RingTransition>(),
      ]);
      expect(streamed.map((event) => event.event)).toEqual([
        "ring.transition",
        "ring.transition",
        "ring.transition",
        "fixture.action.executed",
        "ring.transition",
      ]);
      expect(streamed[2].payload).toMatchObject({
        frame: { phase: "latched" },
        hapticIntent: { type: "play", waveformID: 0 },
      });
      expect(streamed.filter((event) => event.event === "fixture.action.executed")).toHaveLength(1);

      const committed = await mouse.request<RingTransition>(["simulate", "move", "0", "-20"]);
      expect(committed.result.frame.phase).toBe("committed");
      expect(committed.result.cursorVisibilityIntent).toBe("none");
      expect(committed.result.actionToPerform).toBeNull();

      await mouse.request(["simulate", "invoke", "0", "0"]);
      await mouse.request(["simulate", "move", "0", "-30"]);
      const clicked = await mouse.request<RingTransition>(["simulate", "click"]);
      expect(clicked.result.frame.phase).toBe("cancelled");
      expect(clicked.result.cursorVisibilityIntent).toBe("restore");
      expect(clicked.result.actionToPerform).toBeNull();

      await mouse.request(["simulate", "invoke", "0", "0"]);
      const clickAway = await mouse.request<RingTransition>(["simulate", "click"]);
      expect(clickAway.result.frame.phase).toBe("cancelled");
      expect(clickAway.result.cursorVisibilityIntent).toBe("restore");

      await mouse.request(["simulate", "invoke", "0", "0"]);
      await mouse.request(["simulate", "release"]);
      const toggled = await mouse.request<RingTransition>(["simulate", "invoke", "20", "30"]);
      expect(toggled.result.frame.phase).toBe("cancelled");

      await mouse.request(["simulate", "invoke", "0", "0"]);
      const dismissed = await mouse.request<RingTransition>(["simulate", "dismiss"]);
      expect(dismissed.result.frame.phase).toBe("cancelled");
    }, 120_000);

    it("owns a private Unix socket and removes it on deterministic shutdown", async () => {
      await using mouse = await createNativeMouseGym();

      expect(await mouse.directoryMode()).toBe(0o700);
      expect(await mouse.socketMode()).toBe(0o600);
      expect((await mouse.request<{ ok: boolean }>(["doctor"])).result.ok).toBe(true);

      await mouse.stopDaemon();
      await expect(stat(mouse.socketPath)).rejects.toMatchObject({ code: "ENOENT" });

      const unavailable = await mouse.cli(["status"]);
      expect(unavailable.exitCode).toBe(3);
      expect(unavailable.response).toBeUndefined();
      expect(unavailable.stderr).not.toBe("");
    }, 120_000);
  });

import Darwin
import Foundation

final class SocketFrameIO: @unchecked Sendable {
  let fileDescriptor: Int32
  let maximumFrameBytes: Int

  private let sendLock = NSLock()
  private let closeLock = NSLock()
  private var isClosed = false
  private var receiveBuffer = Data()

  init(fileDescriptor: Int32, maximumFrameBytes: Int) throws {
    guard maximumFrameBytes > 0 else {
      throw ControlTransportError.frameTooLarge(limit: maximumFrameBytes)
    }
    self.fileDescriptor = fileDescriptor
    self.maximumFrameBytes = maximumFrameBytes
    try configureNoSigPipe(fileDescriptor)
  }

  deinit {
    close()
  }

  func close() {
    closeLock.lock()
    guard !isClosed else {
      closeLock.unlock()
      return
    }
    isClosed = true
    Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    Darwin.close(fileDescriptor)
    closeLock.unlock()
  }

  func send<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    guard data.count <= maximumFrameBytes else {
      throw ControlTransportError.frameTooLarge(limit: maximumFrameBytes)
    }
    data.append(0x0A)
    try sendRaw(data)
  }

  func sendRaw(_ data: Data) throws {
    sendLock.lock()
    defer { sendLock.unlock() }

    var sent = 0
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      while sent < rawBuffer.count {
        let result = Darwin.send(
          fileDescriptor,
          baseAddress.advanced(by: sent),
          rawBuffer.count - sent,
          0
        )
        if result > 0 {
          sent += result
        } else if result == -1, errno == EINTR {
          continue
        } else if result == -1, errno == EPIPE || errno == ECONNRESET {
          throw ControlTransportError.connectionClosed
        } else {
          throw posixError("send")
        }
      }
    }
  }

  /// Returns one newline-delimited JSON frame without the delimiter. A clean
  /// EOF between frames returns `nil`; EOF in a partial frame is malformed.
  func readFrame() throws -> Data? {
    while true {
      if let newline = receiveBuffer.firstIndex(of: 0x0A) {
        var frame = Data(receiveBuffer[..<newline])
        receiveBuffer.removeSubrange(...newline)
        if frame.last == 0x0D {
          frame.removeLast()
        }
        guard frame.count <= maximumFrameBytes else {
          throw ControlTransportError.frameTooLarge(limit: maximumFrameBytes)
        }
        guard !frame.isEmpty else {
          throw ControlTransportError.malformedFrame
        }
        return frame
      }

      guard receiveBuffer.count <= maximumFrameBytes else {
        throw ControlTransportError.frameTooLarge(limit: maximumFrameBytes)
      }

      var bytes = [UInt8](repeating: 0, count: 4_096)
      let count = Darwin.recv(fileDescriptor, &bytes, bytes.count, 0)
      if count > 0 {
        receiveBuffer.append(contentsOf: bytes.prefix(count))
      } else if count == 0 {
        guard receiveBuffer.isEmpty else {
          throw ControlTransportError.malformedFrame
        }
        return nil
      } else if errno == EINTR {
        continue
      } else if errno == ECONNRESET || errno == EBADF || errno == ENOTCONN {
        return nil
      } else {
        throw posixError("recv")
      }
    }
  }
}

struct SocketIdentity: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t
}

func preparePrivateSocketDirectory(for socketURL: URL) throws {
  let parentURL = socketURL.deletingLastPathComponent()
  let parentPath = parentURL.path
  var info = stat()

  if lstat(parentPath, &info) == -1 {
    guard errno == ENOENT else { throw posixError("lstat") }
    do {
      try FileManager.default.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw error
    }
    guard lstat(parentPath, &info) == 0 else { throw posixError("lstat") }
  }

  guard (info.st_mode & S_IFMT) == S_IFDIR,
    info.st_uid == getuid()
  else {
    throw ControlTransportError.insecureSocketDirectory(parentPath)
  }

  guard chmod(parentPath, 0o700) == 0 else { throw posixError("chmod") }
  guard lstat(parentPath, &info) == 0,
    (info.st_mode & 0o777) == 0o700
  else {
    throw ControlTransportError.insecureSocketDirectory(parentPath)
  }
}

func removeStaleSocketIfNeeded(at path: String) throws {
  var info = stat()
  guard lstat(path, &info) == 0 else {
    guard errno == ENOENT else { throw posixError("lstat") }
    return
  }

  guard (info.st_mode & S_IFMT) == S_IFSOCK,
    info.st_uid == getuid()
  else {
    throw ControlTransportError.socketAlreadyInUse(path)
  }

  let probe = try createUnixSocket()
  defer { Darwin.close(probe) }
  do {
    try connectUnixSocket(probe, path: path)
    throw ControlTransportError.socketAlreadyInUse(path)
  } catch let error as ControlTransportError {
    switch error {
    case .systemCall(let operation, let code)
    where operation == "connect" && (code == ECONNREFUSED || code == ENOENT):
      guard unlink(path) == 0 || errno == ENOENT else {
        throw posixError("unlink")
      }
    default:
      throw error
    }
  }
}

func socketIdentity(at path: String) throws -> SocketIdentity {
  var info = stat()
  guard lstat(path, &info) == 0 else { throw posixError("lstat") }
  return .init(device: info.st_dev, inode: info.st_ino)
}

func unlinkSocketIfMatching(path: String, identity: SocketIdentity) {
  guard let current = try? socketIdentity(at: path), current == identity else { return }
  _ = unlink(path)
}

func createUnixSocket() throws -> Int32 {
  let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fileDescriptor >= 0 else { throw posixError("socket") }
  do {
    try configureNoSigPipe(fileDescriptor)
    return fileDescriptor
  } catch {
    Darwin.close(fileDescriptor)
    throw error
  }
}

func configureNoSigPipe(_ fileDescriptor: Int32) throws {
  var enabled: Int32 = 1
  let result = withUnsafePointer(to: &enabled) { pointer in
    setsockopt(
      fileDescriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      pointer,
      socklen_t(MemoryLayout<Int32>.size)
    )
  }
  guard result == 0 else { throw posixError("setsockopt(SO_NOSIGPIPE)") }
}

func connectUnixSocket(_ fileDescriptor: Int32, path: String) throws {
  let result = try withUnixSocketAddress(path: path) { address, length in
    Darwin.connect(fileDescriptor, address, length)
  }
  guard result == 0 else { throw posixError("connect") }
}

func bindUnixSocket(_ fileDescriptor: Int32, path: String) throws {
  let result = try withUnixSocketAddress(path: path) { address, length in
    Darwin.bind(fileDescriptor, address, length)
  }
  guard result == 0 else { throw posixError("bind") }
}

private func withUnixSocketAddress<Result>(
  path: String,
  body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) throws -> Result {
  let pathBytes = Array(path.utf8)
  var address = sockaddr_un()
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard !pathBytes.contains(0), pathBytes.count < capacity else {
    throw ControlTransportError.invalidSocketPath(path)
  }

  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
    pathPointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { bytes in
      bytes.initialize(repeating: 0, count: capacity)
      for (index, byte) in pathBytes.enumerated() {
        bytes[index] = byte
      }
    }
  }

  return try withUnsafePointer(to: &address) { addressPointer in
    try addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

func posixError(_ operation: String, code: Int32 = errno) -> ControlTransportError {
  .systemCall(operation: operation, code: code)
}

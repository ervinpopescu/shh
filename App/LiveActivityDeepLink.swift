import Foundation

enum LiveActivityDeepLink {
  static let scheme = "shh"
  static let sessionHost = "session"

  static func url(sessionID: UUID) -> URL {
    URL(string: "\(scheme)://\(sessionHost)/\(sessionID.uuidString)")!
  }

  static func sessionID(from url: URL) -> UUID? {
    guard url.scheme == scheme,
      url.host == sessionHost,
      url.query == nil,
      url.fragment == nil
    else { return nil }

    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !path.isEmpty, !path.contains("/") else { return nil }
    return UUID(uuidString: path)
  }
}

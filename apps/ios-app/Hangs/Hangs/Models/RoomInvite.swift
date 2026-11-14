//
//  RoomInvite.swift
//  Hangs
//
//  #212: how a guest gets into a same-room game.
//

import Foundation

/// `POST /rooms`: the host's room and the token its QR code and link carry.
nonisolated struct RoomCreated: Decodable, Sendable, Equatable {
    let roomId: String
    let joinToken: String
    let sessionId: String

    /// The universal link in the QR code and the shared message. Without the
    /// app it opens the trubbo.app join page, which leads to the App Store.
    var inviteURL: URL { inviteURL(isBeta: BetaApp.isBetaBuild) }

    func inviteURL(isBeta: Bool) -> URL {
        var components = URLComponents(string: RoomInvite.joinPageURL(isBeta: isBeta))
        components?.queryItems = [URLQueryItem(name: RoomInvite.tokenQueryItem, value: joinToken)]
        return components?.url ?? URL(fileURLWithPath: "/")
    }

    /// The same link in the QR code, marked so the server can count scans
    /// apart from shared links (#212.5). The mark is a fragment: universal
    /// link matching and the join page only look at the path and `t`.
    var qrURL: URL {
        var components = URLComponents(url: inviteURL, resolvingAgainstBaseURL: false)
        components?.fragment = RoomInvite.qrFragment
        return components?.url ?? inviteURL
    }

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case joinToken = "join_token"
        case sessionId = "session_id"
    }
}

/// A game waiting to start on the guest's Wi-Fi (`POST /rooms/nearby`).
nonisolated struct NearbyRoom: Decodable, Sendable, Equatable, Identifiable {
    let roomId: String
    let hostName: String
    let hostColor: String?
    let playerCount: Int

    var id: String { roomId }

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case hostName = "host_name"
        case hostColor = "host_color"
        case playerCount = "player_count"
    }
}

/// Where a guest joins from: a game in the nearby list, a shared link or the
/// scanned QR code (both carry the same token).
nonisolated enum RoomInvite: Equatable, Sendable {
    case nearby(NearbyRoom)
    case token(String)
    case qr(String)

    /// How the guest got in, as the analytics name it (same words as the server's `via`).
    var via: String {
        switch self {
        case .nearby: "nearby"
        case .qr: "qr"
        case .token: "link"
        }
    }

    /// #234: Trubbo Beta invites on `/beta/join` so a link never opens the
    /// other app; the website serves both paths the same way.
    static func joinPageURL(isBeta: Bool = BetaApp.isBetaBuild) -> String {
        "https://trubbo.app" + BetaApp.joinPath(isBeta: isBeta)
    }

    static let tokenQueryItem = "t"
    static let qrFragment = "qr"

    /// A join link as an invite: `.qr` when it came from the QR code.
    static func invite(from url: URL, isBeta: Bool = BetaApp.isBetaBuild) -> RoomInvite? {
        guard let token = token(from: url, isBeta: isBeta) else { return nil }
        return url.fragment == qrFragment ? .qr(token) : .token(token)
    }

    /// The join token in a `https://trubbo.app/join?t=…` link (`/beta/join`
    /// in Trubbo Beta), nil for any other URL.
    static func token(from url: URL, isBeta: Bool = BetaApp.isBetaBuild) -> String? {
        let joinPath = BetaApp.joinPath(isBeta: isBeta)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "trubbo.app",
              components.path == joinPath || components.path == joinPath + "/"
        else { return nil }
        let token = components.queryItems?.first { $0.name == tokenQueryItem }?.value
        return token.flatMap { $0.isEmpty ? nil : $0 }
    }
}

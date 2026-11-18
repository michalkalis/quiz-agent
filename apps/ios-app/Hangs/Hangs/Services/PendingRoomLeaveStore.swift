//
//  PendingRoomLeaveStore.swift
//  Hangs
//
//  #235 F5: keeps the one unsent leave of a game together (`PendingRoomLeave`)
//  and sends it again until the server has it or the room is gone.
//

import Foundation

struct PendingRoomLeaveStore: @unchecked Sendable {
    static let key = "together.pendingLeave"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PendingRoomLeave? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PendingRoomLeave.self, from: $0) }
    }

    /// One record is enough: a newer leave replaces an older one.
    func save(_ leave: PendingRoomLeave) {
        defaults.set(try? JSONEncoder().encode(leave), forKey: Self.key)
    }

    /// Sends `leave` and forgets it once the server has it or no longer has
    /// the room; any other failure keeps it for the next try.
    func deliver(_ leave: PendingRoomLeave, rooms: RoomServiceProtocol, network: NetworkServiceProtocol) async {
        do {
            switch leave {
            case let .guest(roomId, participantId):
                try await rooms.removePlayer(roomId: roomId, participantId: participantId)
            case let .host(sessionId):
                try await network.endSession(sessionId: sessionId)
            }
        } catch NetworkError.serverError(statusCode: 404, _), NetworkError.sessionNotFound {
            // The room is gone already: nothing left to tell.
        } catch {
            return
        }
        // A newer leave saved meanwhile stays for its own send.
        if load() == leave { defaults.removeObject(forKey: Self.key) }
    }

    /// The leave a previous run could not send, if any.
    func resend(rooms: RoomServiceProtocol, network: NetworkServiceProtocol) async {
        guard let leave = load() else { return }
        await deliver(leave, rooms: rooms, network: network)
    }
}

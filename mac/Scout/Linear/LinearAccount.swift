import Foundation
import Observation

@Observable
final class LinearAccount {
    enum Status: Equatable {
        case disconnected(LinearError?)
        case connecting
        case connected(LinearKeyHint, Check)
    }

    enum Check: Equatable {
        case checking
        case passed(LinearViewer, at: Date)
        case failed(LinearError)
    }

    enum Loadable<Value: Equatable>: Equatable {
        case idle
        case loading
        case loaded(Value)
        case failed(LinearError)

        var value: Value? {
            if case .loaded(let value) = self { value } else { nil }
        }
    }

    let preferences: LinearPreferences
    private let api: any LinearAPI
    private let credentials: LinearCredentials
    private(set) var status: Status
    private(set) var teams: Loadable<[LinearTeam]> = .idle
    private(set) var projects: [String: Loadable<[LinearProject]>] = [:]
    private(set) var labels: [String: Loadable<[LinearLabel]>] = [:]
    var draftKey = ""
    var openTeamPicker: String?

    init(api: any LinearAPI, credentials: LinearCredentials, preferences: LinearPreferences) {
        self.api = api
        self.credentials = credentials
        self.preferences = preferences
        status = credentials.hint.map { .connected($0, .checking) } ?? .disconnected(nil)
    }

    var isConnected: Bool {
        if case .connected = status { true } else { false }
    }

    var viewer: LinearViewer? {
        if case .connected(_, .passed(let viewer, _)) = status { viewer } else { nil }
    }

    func connect() async {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, status != .connecting else { return }
        status = .connecting
        do throws(LinearError) {
            let viewer = try await api.perform(LinearOperations.viewer, credential: .apiKey(key)).viewer
            let hint = try credentials.save(key)
            draftKey = ""
            status = .connected(hint, .passed(viewer, at: .now))
            await loadTeams()
        } catch {
            status = .disconnected(error)
        }
    }

    func check() async {
        guard case .connected(let hint, _) = status else { return }
        status = .connected(hint, .checking)
        do throws(LinearError) {
            let viewer = try await perform(LinearOperations.viewer).viewer
            status = .connected(hint, .passed(viewer, at: .now))
            projects = [:]
            labels = [:]
            await loadTeams()
        } catch {
            status = .connected(hint, .failed(error))
        }
    }

    func refresh() async {
        switch status {
        case .connected(_, .checking): await check()
        case .connected(_, .passed): if teams.value == nil { await loadTeams() }
        default: break
        }
    }

    func remove() {
        credentials.remove()
        teams = .idle
        projects = [:]
        labels = [:]
        openTeamPicker = nil
        status = .disconnected(nil)
    }

    func loadTeams() async {
        teams = .loading
        do throws(LinearError) {
            let loaded = try await perform(LinearOperations.teams).teams.nodes
            teams = .loaded(loaded.sorted { $0.key < $1.key })
            if let team = preferences.defaultTeam { await loadTeamDetails(team.id) }
        } catch {
            teams = .failed(error)
        }
    }

    func loadTeamDetails(_ teamID: String) async {
        guard isConnected else { return }
        if projects[teamID]?.value == nil {
            projects[teamID] = .loading
            do throws(LinearError) {
                let loaded = try await perform(LinearOperations.projects(team: teamID)).team?.projects.nodes ?? []
                projects[teamID] = .loaded(loaded.filter(\.isOpen).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            } catch {
                projects[teamID] = .failed(error)
            }
        }
        if labels[teamID]?.value == nil {
            labels[teamID] = .loading
            do throws(LinearError) {
                labels[teamID] = .loaded(try await perform(LinearOperations.labels(team: teamID)).team?.labels.nodes ?? [])
            } catch {
                labels[teamID] = .failed(error)
            }
        }
    }

    func team(id: String) -> LinearTeam? {
        teams.value?.first { $0.id == id }
    }

    private func perform<Response>(_ operation: LinearOperation<Response>) async throws(LinearError) -> Response {
        guard let credential = try credentials.current() else { throw .unauthorized }
        return try await api.perform(operation, credential: credential)
    }
}

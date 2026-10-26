import Foundation
import HearthKit

/// Builds a fresh widget snapshot without the app running: the relay's cached
/// Google events (or the last ones the app saved) plus EventKit, merged. The
/// StandBy widgets call this when their snapshot is more than 25 minutes old,
/// so the nightstand stays current overnight.
public enum WidgetRefresh {
    public static let staleAfter: TimeInterval = 25 * 60

    public static func run(services: AppServices, now: Date) async -> WidgetSnapshot? {
        let household = services.database.load(HealthResponse.self, key: StoreKey.health)?.household ?? .placeholder
        let calendar = household.fmt.calendar
        let from = calendar.startOfDay(for: now)
        let to = calendar.date(byAdding: .day, value: 2, to: from) ?? now.addingTimeInterval(2 * 86400)

        var google = services.database.load(EventsResponse.self, key: StoreKey.googleEvents)
        if let credentials = RelayCredentials.load(from: services.secrets),
            let fresh = try? await services.makeRelay(credentials).events(from: from, to: to, refresh: false)
        {
            google = fresh
        }
        let apple = await services.calendar.events(from: from, to: to, calendarIds: nil)
        guard google != nil || !apple.isEmpty else { return nil }
        let agenda = Agenda(events: (google?.events ?? []) + apple, household: household)
        return WidgetSnapshot.make(agenda: agenda, now: now, fetchedAt: google?.fetchedAt)
    }
}

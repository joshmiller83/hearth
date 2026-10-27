import HearthCore
import HearthKit
import SwiftUI

/// People: the inner circle, what's coming up for them, and small ways to show up.
struct PeopleView: View {
    @Environment(AppModel.self) private var app
    @Binding var tab: AppTab
    @State private var adding = false
    @State private var planning = false

    var body: some View {
        let people = app.people
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("People").font(.hTitle).displayTracking().foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    RoundIconButton(symbol: "plus", label: "Add someone", filled: true) { adding = true }
                }
                .padding(.leading, 4)
                Text("The people who matter most, and small ways to show it.")
                    .font(.custom(Typeface.regular, size: 15, relativeTo: .body)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4).padding(.top, -6)
                if people.circle.isEmpty {
                    Notice(
                        symbol: "person.2", text: "Add the people who matter most, and Hearth will suggest small ways to show up.",
                        tint: .ice)
                } else {
                    circle
                }
                comingUp
                ideas
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await people.refreshIdeas(force: true) }
        .task {
            await people.ensurePartner()
            await people.refreshIdeas()
        }
        .sheet(isPresented: $adding) { AddPersonView() }
        .navigationDestination(isPresented: $planning) { PartnerPlannerView() }
    }

    /// The inner circle: rings in ember for the partner and anyone with a day coming up.
    var circle: some View {
        let people = app.people
        let soon = Set(people.occasions.filter { $0.daysAway <= 14 }.compactMap(\.personId))
        return ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(people.ordered) { person in
                    Button {
                        if person.isPartner { planning = true }
                    } label: {
                        VStack(spacing: 6) {
                            Text(person.initial)
                                .font(.custom(Typeface.bold, size: 22, relativeTo: .title2))
                                .foregroundStyle(person.isPartner ? Theme.emberSoft : Theme.ink)
                                .frame(width: 50, height: 50)
                                .background(person.isPartner ? Theme.emberDeep : Theme.chip, in: Circle())
                                .padding(3)
                                .overlay(
                                    Circle().strokeBorder(
                                        person.isPartner || soon.contains(person.id) ? Theme.ember : Theme.stoneDeep, lineWidth: 2.5))
                            Text(person.shortName).font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote)).foregroundStyle(
                                Theme.ink
                            )
                            .lineLimit(1)
                        }
                        .frame(width: 64)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from People", systemImage: "minus.circle", role: .destructive) { people.remove(person) }
                    }
                    .accessibilityHint(person.isPartner ? "Opens the planner" : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inner circle")
    }

    @ViewBuilder var comingUp: some View {
        let people = app.people
        let occasions = Array(people.occasions.prefix(5))
        if !occasions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Coming up").eyebrow().padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(occasions.enumerated()), id: \.element.id) { index, occasion in
                        OccasionRow(occasion: occasion, tab: $tab, planning: $planning)
                            .overlay(alignment: .top) { if index > 0 { Hairline() } }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }

    @ViewBuilder var ideas: some View {
        let people = app.people
        if !people.circle.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Small ways to show up").eyebrow().padding(.horizontal, 4)
                switch people.ideasPhase {
                case .working:
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.muted)
                        Text("Reading your mail and calendars…").font(.hMeta).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 8)
                case .failed(let message):
                    Notice(text: message)
                case .idle:
                    if people.ideas.isEmpty {
                        Text("Nothing to suggest today.").font(.hBody).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                    }
                }
                ForEach(people.ideas) { idea in IdeaCard(idea: idea) }
                Text("Ideas come from your own mail and calendars. Nothing reaches anyone until you send it.")
                    .font(.custom(Typeface.regular, size: 13, relativeTo: .footnote)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4).padding(.top, 4)
            }
        }
    }
}

/// "19 DAYS · Anniversary with Robin · Sat, Nov 14 · three ideas ready".
private struct OccasionRow: View {
    @Environment(AppModel.self) private var app
    let occasion: Occasion
    @Binding var tab: AppTab
    @Binding var planning: Bool

    var isPartners: Bool { occasion.personId != nil && occasion.personId == app.people.partner?.id }

    var body: some View {
        if isPartners {
            Button {
                planning = true
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the planner")
        } else {
            row
        }
    }

    var row: some View {
        let people = app.people
        return HStack(spacing: 12) {
            VStack(spacing: 1) {
                if occasion.daysAway == 0 {
                    Text("TODAY").font(.custom(Typeface.bold, size: 11, relativeTo: .caption2))
                } else {
                    Text("\(occasion.daysAway)").font(.custom(Typeface.display, size: 20, relativeTo: .title3))
                    Text(occasion.daysAway == 1 ? "DAY" : "DAYS").font(.custom(Typeface.bold, size: 10, relativeTo: .caption2)).tracking(
                        0.4)
                }
            }
            .foregroundStyle(Theme.emberSoft)
            .frame(width: 48, height: 48)
            .background(Theme.emberDeep, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 2) {
                Text(occasion.title).font(.custom(Typeface.bold, size: 15, relativeTo: .body)).foregroundStyle(Theme.ink)
                Text(people.line(occasion)).font(.custom(Typeface.regular, size: 13, relativeTo: .footnote)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPartners {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
            } else if occasion.kind == .birthday, occasion.personId != nil {
                Button("Draft card") { draftCard() }
                    .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Theme.chip, in: Capsule())
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// Hands the card to Ask, which reads their mail and proposes a note and a reminder.
    func draftCard() {
        let people = app.people
        let name = people.circle.first { $0.id == occasion.personId }.map {
            $0.shortName == $0.name ? $0.name : "\($0.shortName) (\($0.name))"
        }
        var question =
            "\(occasion.title) is \(app.household.fmt.shortDay(occasion.date)). Draft a short card note in my voice for \(name ?? "them")"
        if let by = Occasions.mailBy(occasion, now: app.now, calendar: app.household.fmt.calendar) {
            question += ", and remind me to mail it by \(app.household.fmt.shortDay(by))"
        }
        tab = .ask
        Task { await app.ask.ask(question + ".") }
    }
}

/// One idea: where it came from, what to do, and its steps.
private struct IdeaCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let idea: PeopleIdeasPrompt.Idea
    @State private var copied = false

    var body: some View {
        let people = app.people
        VStack(alignment: .leading, spacing: 10) {
            if !idea.source.isEmpty {
                Text(idea.source).font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.ice)
            }
            Text(idea.title).font(.custom(Typeface.bold, size: 17, relativeTo: .headline)).foregroundStyle(Theme.ink)
            if !idea.body.isEmpty {
                Text(idea.body).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.muted)
            }
            ForEach(idea.actions.filter { people.ran[$0.id] != nil }) { step in
                if let ran = people.ran[step.id] { done(step, ran) }
            }
            let waiting = idea.actions.filter { people.ran[$0.id] == nil }
            if !waiting.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { index, step in
                        Button(step.label) { Task { await people.run(step) } }
                            .buttonStyle(.pill(index == 0 && idea.actions.first?.id == step.id ? .primary : .secondary, height: 42))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder func done(_ step: AskProposal, _ ran: PeopleModel.Ran) -> some View {
        let people = app.people
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(ran.text, systemImage: ran.failed ? "exclamationmark.circle" : "checkmark")
                    .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(ran.failed ? Theme.emberSoft : Theme.iceSoft)
                Spacer()
                if !ran.failed, step.kind != .note, step.kind != .link {
                    TextButton(title: "Undo") { Task { await people.undo(step.id) } }
                }
            }
            if let note = ran.note {
                Text(note).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.inkSoft)
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = note
                    copied = true
                }
                .font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.iceSoft)
            }
            if let link = ran.link {
                Button("Open \(link.host ?? "the page")") { openURL(link) }
                    .font(.custom(Typeface.bold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.iceSoft)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.iceDeep, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Adds someone from Contacts.
struct AddPersonView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PersonCard] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search your contacts", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(results, id: \.name) { card in
                        let added = app.people.circle.contains { $0.id == card.name.lowercased() }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.name).font(.hRowTitle)
                                if let line = detail(card) { Text(line).font(.hMeta).foregroundStyle(Theme.muted) }
                            }
                            Spacer()
                            Button(added ? "Added" : "Add") { app.people.add(card) }
                                .disabled(added)
                                .font(.hLabel)
                        }
                    }
                } footer: {
                    Text("Hearth keeps your list on this phone. Birthdays and anniversaries come from each contact card.")
                }
            }
            .navigationTitle("Add someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                results = await app.people.search(query)
            }
        }
        .preferredColorScheme(.dark)
    }

    func detail(_ card: PersonCard) -> String? {
        var parts: [String] = []
        if let relation = card.relation { parts.append(relation) }
        if let month = card.birthdayMonth, let day = card.birthdayDay { parts.append("birthday \(Fmt.monthsShort[month - 1]) \(day)") }
        if let city = card.city { parts.append(city) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

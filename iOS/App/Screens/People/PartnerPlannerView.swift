import HearthCore
import HearthKit
import SwiftUI

/// The partner planner: the surprise guard, the plan's steps, three ideas, the
/// things the partner loves (only what the owner adds), and a little thing for
/// this week. The plan becomes a private hold on the owner's own calendar.
struct PartnerPlannerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var addingLove = false
    @State private var newLove = ""

    var body: some View {
        let people = app.people
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        Text("People")
                    }
                    .font(.custom(Typeface.semibold, size: 16, relativeTo: .body))
                    .foregroundStyle(Theme.ember)
                    .frame(minHeight: Theme.touch)
                }
                header
                guardRow
                planSteps
                pickPlan
                loves
                littleThing
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { ctaBar }
        .task { await people.refreshPlans() }
        .alert("Something \(people.partner?.shortName ?? "they") loves", isPresented: $addingLove) {
            TextField("Lilacs, a band, an author", text: $newLove)
            Button("Add") {
                people.addLove(newLove)
                newLove = ""
            }
            Button("Cancel", role: .cancel) { newLove = "" }
        } message: {
            Text("Only what you know. Hearth never guesses here.")
        }
    }

    var header: some View {
        let people = app.people
        let partner = people.partner
        return HStack(spacing: 14) {
            Text(partner?.initial ?? "?")
                .font(.custom(Typeface.bold, size: 26, relativeTo: .title))
                .foregroundStyle(Theme.emberSoft)
                .frame(width: 62, height: 62)
                .background(Theme.emberDeep, in: Circle())
                .padding(3)
                .overlay(Circle().strokeBorder(Theme.ember, lineWidth: 2.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(partner?.shortName ?? "Your partner").font(.custom(Typeface.display, size: 30, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                let accounts = app.household.partnerAccounts
                Text(
                    "Partner"
                        + (accounts.isEmpty ? "" : " · \(accounts.joined(separator: " and ")) account\(accounts.count == 1 ? "" : "s")")
                )
                .font(.hMeta).foregroundStyle(Theme.muted)
                if let occasion = people.partnerOccasion {
                    Text(
                        occasion.daysAway == 0
                            ? "\(occasion.title) today"
                            : "\(occasion.kind == .anniversary ? "Anniversary" : "Birthday") in \(occasion.daysAway) day\(occasion.daysAway == 1 ? "" : "s")"
                    )
                    .font(.custom(Typeface.semibold, size: 13, relativeTo: .footnote)).foregroundStyle(Theme.emberSoft)
                }
            }
        }
    }

    var guardRow: some View {
        let people = app.people
        let partnerName = people.partner?.shortName ?? "your partner"
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.iceSoft)
                .frame(width: 40, height: 40).background(Theme.iceDeep, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { people.surpriseGuard }, set: { people.setSurpriseGuard($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Surprise guard").font(.hCardTitle).foregroundStyle(Theme.ink)
                    Text(
                        "Holds stay on your own accounts, marked private, and off \(partnerName)'s and the \(app.household.familyCalendar) calendar."
                    )
                    .font(.hMeta).foregroundStyle(Theme.muted)
                }
            }
            .tint(Theme.ember)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder var planSteps: some View {
        let people = app.people
        if let day = people.planDay {
            let title = people.partnerOccasion.map { $0.kind == .anniversary ? "Anniversary" : $0.title } ?? "An evening out"
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) · \(app.household.fmt.shortDay(day))").eyebrow().padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(people.steps.enumerated()), id: \.element.id) { index, step in
                        Button {
                            if !step.automatic { people.toggleStep(step.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(step.done ? Theme.ember : .clear)
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                                        step.done ? Theme.ember : Theme.stone, lineWidth: 2)
                                    if step.done {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(
                                            Theme.onEmber)
                                    }
                                }
                                .frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.label).font(.custom(Typeface.semibold, size: 15, relativeTo: .body))
                                        .foregroundStyle(step.done ? Theme.muted : Theme.ink)
                                    Text(step.sub).font(.hMeta).foregroundStyle(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Worked out from the calendars: shown, not ticked by hand.
                        .allowsHitTesting(!step.automatic)
                        .accessibilityAddTraits(step.done ? .isSelected : [])
                        .overlay(alignment: .top) { if index > 0 { Hairline() } }
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }

    @ViewBuilder var pickPlan: some View {
        let people = app.people
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick the plan").eyebrow().padding(.horizontal, 4)
            switch people.planPhase {
            case .working where people.plan.ideas.isEmpty:
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.muted)
                    Text("Thinking of three ways to spend it…").font(.hMeta).foregroundStyle(Theme.muted)
                }
            case .failed(let message):
                Notice(text: message)
            default:
                EmptyView()
            }
            ForEach(people.plan.ideas) { idea in
                let on = idea.id == people.plan.picked
                Button {
                    people.pick(idea.id)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Circle().strokeBorder(on ? Theme.ember : Theme.stone, lineWidth: 2)
                            .overlay { if on { Circle().fill(Theme.ember).padding(5) } }
                            .frame(width: 22, height: 22)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(idea.tag).font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(
                                on ? Theme.emberSoft : Theme.ice)
                            Text(idea.title).font(.custom(Typeface.semibold, size: 16, relativeTo: .body)).foregroundStyle(Theme.ink)
                            Text(idea.sub).font(.hMeta).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(
                        on ? Color(red: 0.14, green: 0.10, blue: 0.07) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(
                            on ? Theme.ember : Theme.line, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .disabled(people.plan.hold != nil)
            }
            if !people.plan.ideas.isEmpty, people.plan.hold == nil {
                Button("Three new ideas") { Task { await people.refreshPlans(force: true) } }
                    .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.ember)
                    .padding(.horizontal, 4)
                    .disabled(people.planPhase == .working)
            }
        }
    }

    var loves: some View {
        let people = app.people
        let name = people.partner?.shortName ?? "They"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Things \(name) loves").eyebrow().padding(.horizontal, 4)
            FlowLayout(spacing: 8) {
                ForEach(people.plan.loves, id: \.self) { love in
                    Text(love)
                        .font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.chipInk)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Theme.chip, in: Capsule())
                        .contextMenu { Button("Remove", systemImage: "minus.circle", role: .destructive) { people.removeLove(love) } }
                }
                Button {
                    addingLove = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 36)
                        .overlay(Capsule().strokeBorder(Theme.stoneDeep, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .accessibilityLabel("Add something \(name) loves")
            }
            Text("Only what you add. Hearth never guesses here.").font(.hMeta).foregroundStyle(Theme.muted).padding(.horizontal, 4)
        }
    }

    @ViewBuilder var littleThing: some View {
        let people = app.people
        if let thing = people.littleThing {
            VStack(alignment: .leading, spacing: 10) {
                Text("A little thing this week").font(.custom(Typeface.bold, size: 12, relativeTo: .caption)).foregroundStyle(Theme.ice)
                Text(thing.title).font(.custom(Typeface.bold, size: 17, relativeTo: .headline)).foregroundStyle(Theme.ink)
                Text(thing.body).font(.custom(Typeface.regular, size: 14, relativeTo: .subheadline)).foregroundStyle(Theme.muted)
                if let ran = people.ran["little"] {
                    Label(ran.text, systemImage: "checkmark").font(.custom(Typeface.semibold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.iceSoft)
                } else if thing.remindAt != nil {
                    Button("Remind me to send a note") { Task { await people.remindLittleThing() } }
                        .buttonStyle(.pill(.secondary, height: 42))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    @ViewBuilder var ctaBar: some View {
        let people = app.people
        if people.picked != nil {
            VStack(spacing: 8) {
                if people.plan.hold != nil {
                    Button("Undo the hold") { Task { await people.undoPlan() } }
                        .buttonStyle(.pill(.secondary, height: 50))
                } else {
                    Button {
                        Task { await people.makePlan() }
                    } label: {
                        if people.planPhase == .working { ProgressView().tint(Theme.onEmber) } else { Text(people.cta) }
                    }
                    .buttonStyle(.pill(.primary, height: 50))
                    .disabled(people.planPhase == .working)
                }
                Text(people.ctaNote).font(.hMeta).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(Theme.bg)
            .overlay(alignment: .top) { Rectangle().fill(Theme.stoneDeep.opacity(0.6)).frame(height: 1) }
        }
    }
}

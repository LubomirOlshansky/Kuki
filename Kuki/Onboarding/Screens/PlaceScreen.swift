import SwiftData
import SwiftUI

/// 所 — where the sensor is right now.
struct PlaceScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(Recorder.self) private var recorder
    @Query(sort: \Place.sortIndex) private var places: [Place]
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var homeRoom: String? {
        guard !model.demo, !recorder.useDemo else { return nil }
        let room = recorder.activeSensor?.room.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return room.isEmpty ? nil : room
    }

    /// The Apple Home room, when it isn't one of the places yet.
    private var unmatchedRoom: String? {
        guard let room = homeRoom else { return nil }
        let match = places.contains { $0.name.compare(room, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return match ? nil : room
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingMetrics.block) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.titleToBody) {
                Eyebrow(kanji: "所", word: "Place")
                ScreenTitle(text: model.demo ? "Where would you like to start?" : "Where is the sensor right now?")
                BodyText("Kūki keeps a history for each room. Move it later from the Now screen.")
                    .padding(.top, 4)
            }
            VStack(spacing: 10) {
                ForEach(places) { place in
                    ChoiceRow(kanji: place.kanji.isEmpty ? " " : place.kanji, title: place.name,
                              selected: model.draft.staged.place == .existing(place.id)) {
                        typing = false
                        model.draft.staged.place = .existing(place.id)
                    }
                }
                if let room = unmatchedRoom {
                    ChoiceRow(kanji: " ", title: room, subtitle: "From Apple Home",
                              selected: model.draft.staged.place == .newPlace(name: room)) {
                        typing = false
                        model.draft.staged.place = .newPlace(name: room)
                    }
                }
                somewhereElse
            }
        }
        .frame(maxWidth: OnboardingMetrics.maxColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
        .onAppear(perform: preselect)
        .onChange(of: model.draft.staged.place, initial: true) { _, choice in
            // An analytics key only — never the name itself.
            if case .existing(let id) = choice {
                model.stagedPlaceKey = OnboardingAnalytics.placeKey(places.first { $0.id == id }?.name)
            } else {
                model.stagedPlaceKey = "custom"
            }
        }
    }

    @ViewBuilder
    private var somewhereElse: some View {
        let custom: String? = {
            if case .newPlace(let name) = model.draft.staged.place, name != unmatchedRoom { return name }
            return nil
        }()
        if typing {
            HStack(spacing: 10) {
                TextField("Name the room", text: $typed)
                    .font(Typeface.body)
                    .foregroundStyle(Ink.ink)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit(addTyped)
                    .onChange(of: typed) { _, v in if v.count > 30 { typed = String(v.prefix(30)) } }
                Button("Add", action: addTyped)
                    .font(Typeface.body.weight(.medium))
                    .foregroundStyle(Ink.ai)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.paperRaised))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.ink, lineWidth: 1.5))
            .onAppear { fieldFocused = true }
        } else {
            ChoiceRow(kanji: " ", title: custom ?? "Somewhere else…", subtitle: custom == nil ? nil : "A new place",
                      selected: custom != nil) {
                typed = custom ?? ""
                typing = true
            }
        }
    }

    private func addTyped() {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...30).contains(name.count) else { return }
        if let existing = places.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            model.draft.staged.place = .existing(existing.id)
        } else {
            model.draft.staged.place = .newPlace(name: name)
        }
        typing = false
        fieldFocused = false
    }

    private func preselect() {
        guard model.draft.staged.place == nil else { return }
        let refs = places.map { PlaceRef(id: $0.id, name: $0.name, kanji: $0.kanji, sortIndex: $0.sortIndex) }
        model.draft.staged.place = OnboardingPreselect.place(places: refs, homeKitRoom: homeRoom,
                                                             goals: model.draft.answers.goals,
                                                             current: recorder.currentPlaceID)
    }
}

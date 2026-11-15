import SwiftData
import SwiftUI

/// 場所 — where the sensor is now. Pick, add, rename, remove.
struct PlaceSheet: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Place.sortIndex) private var places: [Place]

    @State private var newName = ""
    @State private var renaming: Place?
    @State private var showingRename = false
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(places) { place in
                        Button {
                            recorder.move(to: place)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Text(verbatim: place.kanji.isEmpty ? "・" : place.kanji)
                                    .font(Typeface.mincho(20))
                                    .foregroundStyle(Ink.inkSoft)
                                    .frame(width: 44, alignment: .leading)
                                Text(place.displayName)
                                    .font(Typeface.body)
                                    .foregroundStyle(Ink.ink)
                                Spacer()
                                if place.id == recorder.currentPlaceID {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 7))
                                        // Ink: "selected" isn't an air level, so no pigment.
                                        .foregroundStyle(Ink.ink)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityAddTraits(place.id == recorder.currentPlaceID ? .isSelected : [])
                        .contextMenu {
                            Button("Rename") { rename(place) }
                            Button("Delete", role: .destructive) { delete(place) }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(place) }
                            Button("Rename") { rename(place) }
                        }
                    }
                } header: {
                    Text("Where is the sensor now?")
                } footer: {
                    Text("Moving it starts a \(recorder.settleMinutes)-minute settling period — the CO₂ cell needs time to take on the new room, so those minutes are left out of comparisons.",
                         comment: "Places sheet footer. Placeholder is a number of minutes. 'Settling' = the sensor adapting to the air of a new room.")
                }

                Section("New place") {
                    HStack {
                        TextField(String(localized: "Hallway, balcony, kid's room…",
                                         comment: "Places sheet: placeholder in the field for naming a new room"),
                                  text: $newName)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.paper)
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename place", isPresented: $showingRename, presenting: renaming) { place in
                TextField(String(localized: "Name", comment: "Rename place alert: placeholder for the room's name"),
                          text: $renameText)
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    // Against the shown name: confirming an untouched
                    // seeded place's translation keeps it seeded.
                    if !name.isEmpty, name != place.displayName {
                        place.name = name
                        try? context.save()
                        recorder.placeEdited(place)
                        Analytics.track("place_renamed")
                        UsageAnalytics.shared.refreshProperties()
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .presentationDetents([.medium, .large])
        #if targetEnvironment(macCatalyst)
        // The Mac sheet is a window that needs a floor; on iPhone this would
        // be wider than a 375 pt screen, and the detents already size it.
        .frame(minWidth: 380, minHeight: 440)
        #endif
    }

    private func rename(_ place: Place) {
        renameText = place.displayName
        renaming = place
        showingRename = true
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let place = Place(name: name, sortIndex: (places.map(\.sortIndex).max() ?? 0) + 1)
        context.insert(place)
        try? context.save()
        recorder.placeEdited(place)
        Analytics.track("place_added", ["places_count": places.count + 1])
        UsageAnalytics.shared.refreshProperties()
        newName = ""
        recorder.move(to: place)
        dismiss()
    }

    private func delete(_ place: Place) {
        // Readings keep their place name, so history stays intact.
        recorder.placeDeleted(place)
        context.delete(place)
        try? context.save()
        // Deleting the sensor's place left it nowhere, and it recorded
        // "Unplaced" until the next sync or launch: it starts again in the
        // first place, the recorder's rule for a place that's gone.
        recorder.placesDidChange()
        Analytics.track("place_deleted", ["places_count": max(0, places.count - 1)])
        UsageAnalytics.shared.refreshProperties()
    }
}

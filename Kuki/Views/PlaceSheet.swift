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
                                Text(place.kanji.isEmpty ? "・" : place.kanji)
                                    .font(Typeface.mincho(20))
                                    .foregroundStyle(Ink.inkSoft)
                                    .frame(width: 44, alignment: .leading)
                                Text(place.name)
                                    .font(Typeface.body)
                                    .foregroundStyle(Ink.ink)
                                Spacer()
                                if place.id == recorder.currentPlaceID {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Ink.matcha)
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
                    Text("Moving it starts a \(recorder.settleMinutes)-minute settling period — the CO₂ cell needs time to take on the new room, so those minutes are left out of comparisons.")
                }

                Section("New place") {
                    HStack {
                        TextField("Hallway, balcony, kid's room…", text: $newName)
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
                TextField("Name", text: $renameText)
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, name != place.name {
                        place.name = name
                        try? context.save()
                        recorder.placeEdited(place)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .frame(minWidth: 380, minHeight: 440)
    }

    private func rename(_ place: Place) {
        renameText = place.name
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
        newName = ""
        recorder.move(to: place)
        dismiss()
    }

    private func delete(_ place: Place) {
        // Readings keep their place name, so history stays intact.
        recorder.placeDeleted(place)
        context.delete(place)
        try? context.save()
    }
}

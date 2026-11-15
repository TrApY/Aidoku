//
//  MigrationOptionsView.swift
//  Aidoku
//
//  The sheet shown before migrating (as Tachimanga): what to take to the destination and what happens to
//  the original entry.
//

import AidokuRunner
import SwiftUI

struct MigrationOptionsView: View {
    /// Entries to migrate (the title says «1 entrada» or «N entradas»).
    let count: Int
    /// Single migration: the destination, its source name (a server source's own name for Suwayomi) and
    /// what «Ver ficha» does.
    var destination: AidokuRunner.Manga?
    var destinationSource: AidokuRunner.Source?
    var destinationSourceName: String?
    var showEntry: (() -> Void)?
    let start: (MigrationOptions) -> Void

    @State private var options = MigrationOptions.load()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let destination {
                    Section {
                        destinationHeader(destination)
                    }
                }

                Section(header: Text(NSLocalizedString("MIGRATION_DATA_TO_INCLUDE"))) {
                    checkbox("MIGRATION_READ_CHAPTERS", isOn: $options.readChapters)
                    checkbox("MIGRATION_CATEGORIES", isOn: $options.categories)
                    checkbox("MIGRATION_TRACKING", isOn: $options.tracking)
                }

                Section {
                    checkbox("MIGRATION_KEEP_ORIGINAL", isOn: $options.keepOriginal)
                    checkbox("MIGRATION_DELETE_DOWNLOADS", isOn: $options.deleteDownloads)
                } header: {
                    Text(NSLocalizedString("MIGRATION_ORIGINAL_ENTRY"))
                } footer: {
                    Text(options.noteKeys(count: count).map { NSLocalizedString($0) }.joined(separator: " "))
                }

                Section {
                    Button {
                        options.save()
                        let chosen = options
                        dismiss()
                        start(chosen)
                    } label: {
                        Text(NSLocalizedString("MIGRATION_START"))
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(
                count == 1
                    ? NSLocalizedString("MIGRATE_ONE_ITEM?")
                    : String(format: NSLocalizedString("MIGRATE_%i_ITEMS?"), count)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("CANCEL")) {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    func destinationHeader(_ manga: AidokuRunner.Manga) -> some View {
        HStack(spacing: 12) {
            MangaCoverView(
                source: destinationSource,
                coverImage: manga.cover ?? "",
                width: 48,
                height: 72
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(manga.title)
                    .font(.headline)
                    .lineLimit(2)
                if let destinationSourceName {
                    Text(destinationSourceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let showEntry {
                    Button {
                        dismiss()
                        showEntry()
                    } label: {
                        Text(NSLocalizedString("MIGRATION_VIEW_ENTRY") + " →")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    func checkbox(_ key: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                Text(NSLocalizedString(key))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

//
//  FilterGroupsView.swift
//  Aidoku
//
//  Created by Skitty on 2/25/26.
//

import SwiftUI

struct FilterGroupsView: View {
    @State private var groups: [FilterGroup] = []

    @State private var editingGroupTitle: EditingGroupTitle?
    @State private var showCreateSheet = false
    @State private var showRenameFailedAlert = false

    struct EditingGroupTitle: Identifiable {
        var id: String { value}
        let value: String
    }

    private enum SheetID: String {
        case create
    }

    @Namespace private var transitionNamespace

    var body: some View {
        List {
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                HStack {
                    Text(group.title)
                    Spacer()
                    Button {
                        editingGroupTitle = .init(value: group.title)
                    } label: {
                        Image(systemName: "pencil.circle")
                            .scaleEffect(1.2)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 6)
                }
                .contextMenu {
                    Button {
                        editingGroupTitle = .init(value: group.title)
                    } label: {
                        Label(NSLocalizedString("EDIT"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(at: IndexSet(integer: index))
                    } label: {
                        Label(NSLocalizedString("DELETE"), systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: onDelete)
            .onMove(perform: onMove)
        }
        .animation(.default, value: groups)
        .environment(\.editMode, Binding.constant(.active))
        .navigationTitle(NSLocalizedString("FILTER_GROUPS"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .matchedTransitionSourcePlease(id: SheetID.create, in: transitionNamespace)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            FilterGroupCreateView()
                .navigationTransitionZoom(sourceID: SheetID.create, in: transitionNamespace)
        }
        .sheet(item: $editingGroupTitle) { editingGroupTitle in
            FilterGroupCreateView(editingGroupTitle: editingGroupTitle.value)
        }
        .alert(NSLocalizedString("RENAME_CATEGORY_FAIL"), isPresented: $showRenameFailedAlert) {
            Button(NSLocalizedString("OK"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("RENAME_CATEGORY_FAIL_INFO"))
        }
        .task {
            let loaded = await DataRepositories.shared.categories.filterGroups()
            // the first load is not animated (it used to be there from the start)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                groups = loaded
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateCategories)) { _ in
            Task {
                groups = await DataRepositories.shared.categories.filterGroups()
            }
        }
    }

    func onDelete(at offsets: IndexSet) {
        Task {
            var removedOffsets: IndexSet = []
            for offset in offsets {
                let group = groups[offset]
                let success = await self.removeGroup(title: group.title)
                if success {
                    removedOffsets.insert(offset)
                }
            }
            groups.remove(atOffsets: removedOffsets)
            NotificationCenter.default.post(name: .updateCategories, object: nil)
        }
    }

    func onMove(from source: IndexSet, to destination: Int) {
        let sourceIndices = source.sorted()
        var adjustedDestination = destination

        // if moving down, adjust destination for each item removed before it
        // e.g. moving [0] to the end of a three item list will have destination 3,
        //      but we need to move it to index 2
        if let first = sourceIndices.first, first < destination {
            adjustedDestination -= sourceIndices.count
        }

        let titles = sourceIndices.reversed().map { groups[$0].title }

        // the list moves first (no flicker); the stored order follows, and the reload after the notification
        // shows what was stored
        groups.move(fromOffsets: source, toOffset: destination)

        Task {
            await DataRepositories.shared.categories.move(titles, to: adjustedDestination)
            NotificationCenter.default.post(name: .updateCategories, object: nil)
        }
    }
}

extension FilterGroupsView {
    func removeGroup(title: String) async -> Bool {
        await DataRepositories.shared.categories.remove(title: title)
    }

    func renameGroup(title: String, newTitle: String) {
        if newTitle.lowercased() == "none" || self.groups.map({ $0.title }).contains(newTitle) || newTitle.isEmpty {
            showRenameFailedAlert = true
        } else {
            Task {
                if await DataRepositories.shared.categories.rename(title, to: newTitle) != nil {
                    groups = await DataRepositories.shared.categories.filterGroups()
                    NotificationCenter.default.post(name: .updateCategories, object: nil)
                } else {
                    showRenameFailedAlert = true
                }
            }
        }
    }
}

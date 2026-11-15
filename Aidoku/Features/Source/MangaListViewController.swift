//
//  MangaListViewController.swift
//  Aidoku
//
//  Created by Skitty on 11/19/25.
//

import AidokuRunner
import UIKit

class MangaListViewController: MangaCollectionViewController {
    let source: AidokuRunner.Source

    var getEntries: ((Int) async throws -> AidokuRunner.MangaPageResult)?

    private var hashValues: Set<Int> = []
    private var loaded = false
    private var nextPage = 1
    private var hasMore = true

    init(
        source: AidokuRunner.Source,
        title: String = "",
        listingKind: ListingKind = .default
    ) {
        self.source = source
        super.init()

        self.usesListLayout = listingKind == .list
        self.title = title
    }

    override func configure() {
        super.configure()
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !loaded else { return }
        loaded = true
        Task {
            await loadEntries()
            hideLoadingView()
        }
    }
}

extension MangaListViewController {
    func loadEntries() async {
        do {
            errorView.hide()

            let result = try await getEntries?(nextPage)
            guard let result else { return }

            let inLibrary = await DataRepositories.shared.library.contained(in: result.entries.map(\.identifier))
            let newBookmarks = Set(result.entries.filter { inLibrary.contains($0.identifier) }.map(\.key))
            bookmarkedItems.formUnion(newBookmarks)

            hasMore = result.hasNextPage
            entries += result.entries.filter { hashValues.insert($0.hashValue).inserted }
            nextPage += 1
            updateDataSource()
        } catch {
            errorView.setError(error)
            errorView.show()
        }
    }
}

// MARK: UICollectionViewDelegate
extension MangaListViewController {
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        if indexPath.row == entries.count - 1 && hasMore {
            Task {
                await loadEntries()
            }
        }
    }
}

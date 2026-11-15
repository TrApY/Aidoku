//
//  BrowseViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 1/23/22.
//

import AidokuRunner
import SafariServices
import SwiftUI

class BrowseViewController: BaseTableViewController {
    let viewModel = BrowseViewModel()

    private lazy var dataSource = makeDataSource()

    private lazy var refreshControl = UIRefreshControl()
    private lazy var emptyStackView = EmptyPageStackView()

    private var hasAppliedInitialSnapshot = false

    // SUWA-12: Fuentes / Extensiones / Migrar
    private let tabHeader = UIView()
    private lazy var tabControl = UISegmentedControl(items: [
        NSLocalizedString("EXPLORE_SOURCES"),
        NSLocalizedString("EXPLORE_EXTENSIONS"),
        NSLocalizedString("EXPLORE_MIGRATE")
    ])
    private var tabChildren: [Int: UIViewController] = [:]
    private var sourcesSearchController: UISearchController?
    private static let tabHeaderHeight: CGFloat = 48

    override var tableViewStyle: UITableView.Style {
        .grouped
    }

    override func configure() {
        super.configure()

        title = NSLocalizedString("BROWSE")

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.hidesSearchBarWhenScrolling = false

        // search controller
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        sourcesSearchController = searchController

        // tabs (Tachimanga): a fixed bar under the navigation bar
        tabControl.selectedSegmentIndex = 0
        tabControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabHeader.backgroundColor = .systemBackground
        tabHeader.translatesAutoresizingMaskIntoConstraints = false
        tabHeader.addSubview(tabControl)

        // toolbar buttons
        let deleteButton = UIBarButtonItem(
            title: nil,
            style: .plain,
            target: self,
            action: #selector(deleteSelected)
        )
        deleteButton.image = UIImage(systemName: "trash")
        if #unavailable(iOS 26.0) {
            deleteButton.tintColor = .systemRed
        }
        toolbarItems = [
            deleteButton,
            UIBarButtonItem(systemItem: .flexibleSpace)
        ]

        updateNavbar()
        updateToolbar()

        // configure table view
        tableView.dataSource = dataSource
        tableView.register(
            SourceTableViewCell.self,
            forCellReuseIdentifier: String(describing: SourceTableViewCell.self)
        )
        tableView.register(
            UITableViewHeaderFooterView.self,
            forHeaderFooterViewReuseIdentifier: String(describing: UITableViewHeaderFooterView.self)
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.sectionFooterHeight = 8
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.keyboardDismissMode = .onDrag
        tableView.allowsMultipleSelectionDuringEditing = true

        refreshControl.addTarget(self, action: #selector(refreshSourceLists(_:)), for: .valueChanged)
        tableView.refreshControl = refreshControl

        // empty text
        emptyStackView.imageSystemName = "globe"
        emptyStackView.title = NSLocalizedString("BROWSE_NO_SOURCES")
        emptyStackView.text = NSLocalizedString("BROWSE_NO_SOURCES_TEXT_NEW")
        emptyStackView.buttonText = NSLocalizedString("ADDING_SOURCES_GUIDE_BUTTON")
        emptyStackView.addButtonTarget(self, action: #selector(openGuidePage))
        emptyStackView.showsButton = true
        emptyStackView.isHidden = true
        emptyStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStackView)
        view.addSubview(tabHeader)
        tableView.contentInset.top = Self.tabHeaderHeight
        tableView.verticalScrollIndicatorInsets.top = Self.tabHeaderHeight

        // load data
        Task {
            await viewModel.loadInstalledSources()
            await viewModel.loadPinnedSources()
            updateDataSource()

            Task {
                await viewModel.loadExternalSources()
                viewModel.loadUpdates()
                updateDataSource()
            }

            if viewModel.hasLegacySourceList && !AppSettings.flags.showedLegacySourceListNotice.get() {
                showLegacySourceListNotice()
                AppSettings.flags.showedLegacySourceListNotice.set(true)
            }
        }
    }

    override func constrain() {
        super.constrain()

        NSLayoutConstraint.activate([
            emptyStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            tabHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabHeader.heightAnchor.constraint(equalToConstant: Self.tabHeaderHeight),
            tabControl.leadingAnchor.constraint(equalTo: tabHeader.layoutMarginsGuide.leadingAnchor),
            tabControl.trailingAnchor.constraint(equalTo: tabHeader.layoutMarginsGuide.trailingAnchor),
            tabControl.centerYAnchor.constraint(equalTo: tabHeader.centerYAnchor)
        ])
    }

    override func observe() {
        // source installed/imported/pinned
        addObserver(forName: .updateSourceList) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.viewModel.loadInstalledSources()
                await self.viewModel.loadPinnedSources()
                self.viewModel.loadUpdates()
                if let query = self.navigationItem.searchController?.searchBar.text, !query.isEmpty {
                    self.viewModel.search(query: query)
                }
                self.updateDataSource()
            }
        }
        // active languages changed (Explorar, Añadir fuente)
        addObserver(forName: .browseLanguagesChanged) { [weak self] _ in
            Task { @MainActor in
                self?.updateDataSource()
            }
        }
        // source lists added/removed
        addObserver(forName: .updateSourceLists) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.viewModel.loadExternalSources()
                self.viewModel.loadUpdates()
                self.updateDataSource()
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dataSource.onReorder = { [weak self] snapshot in
            guard let self = self else { return }
            let sourceList = snapshot.itemIdentifiers(inSection: .pinned).map { $0.info.sourceId }
            AppSettings.browse.pinnedList.set(sourceList)

            if sourceList.isEmpty { self.stopEditing() }
            Task { @MainActor in
                await self.viewModel.loadInstalledSources()
                await self.viewModel.loadPinnedSources()
                self.updateDataSource()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.isToolbarHidden = true
        if hasAppliedInitialSnapshot {
            updateDataSource() // «Usado recientemente»
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // fix refresh control snapping height
        refreshControl.didMoveToSuperview()

        // hack to show search bar on initial presentation
        if !navigationItem.hidesSearchBarWhenScrolling {
            navigationItem.hidesSearchBarWhenScrolling = true
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        updateNavbar()
        updateToolbar()
    }
}

extension BrowseViewController {
    func uninstall(sourceKeys: [String]) {
        let containsLocalSource = sourceKeys.contains(where: { $0 == LocalSourceRunner.sourceKey })

        func commit() {
            Task {
                for key in sourceKeys {
                    await SourceManager.shared.remove(sourceKey: key, skipUpdateNotification: true)
                }
                await self.viewModel.loadInstalledSources()
                await self.viewModel.loadPinnedSources()
                self.viewModel.loadUpdates()
                self.updateDataSource()
                self.setEditing(false, animated: true)
            }
        }

        if containsLocalSource {
            self.presentAlert(
                title: NSLocalizedString("REMOVE_LOCAL_SOURCE"),
                message: NSLocalizedString("REMOVE_LOCAL_SOURCE_TEXT"),
                actions: [
                    UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel),
                    UIAlertAction(title: NSLocalizedString("OK"), style: .default) { _ in
                        Task {
                            await LocalFileManager.shared.removeAllLocalFiles()
                        }
                        commit()
                    }
                ]
            )
        } else {
            commit()
        }
    }

    // store update count and display badge
    func checkUpdateCount() {
        let updateCount = viewModel.updatesSources.count
        AppSettings.browse.updateCount.set(updateCount)
        let tabBarItem = tabBarController?.tabBar.items?.first(
            where: { $0.title == NSLocalizedString("BROWSE") }
        )
        tabBarItem?.badgeValue = updateCount > 0 ? String(updateCount) : nil
    }

    func showLegacySourceListNotice() {
        let alert = UIAlertController(
            title: NSLocalizedString("LEGACY_SOURCE_LIST_WARNING"),
            message: NSLocalizedString("LEGACY_SOURCE_LIST_WARNING_INFO"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .cancel) { _ in })
        present(alert, animated: true)
    }

    @objc func refreshSourceLists(_ refreshControl: UIRefreshControl? = nil) {
        Task {
            await viewModel.loadExternalSources(reload: true)
            self.viewModel.loadUpdates()
            updateExternalSources()
            refreshControl?.endRefreshing()
        }
    }

    @objc func openGuidePage() {
        let safariViewController = SFSafariViewController(
            url: URL(string: "https://aidoku.app/help/guides/getting-started/#installing-a-source")!
        )
        present(safariViewController, animated: true)
    }

    @objc func openMigrateSourcePage() {
        let viewController = SwiftUINavigationViewController(rootView: MigrateSourcesView())
        if #available(iOS 26.0, *) {
            viewController.preferredTransition = .zoom { _ in
                self.navigationItem.rightBarButtonItems?.last
            }
        }
        viewController.modalPresentationStyle = .pageSheet
        present(viewController, animated: true)
    }

    @objc func openAddSourcePage() {
        let path = NavigationCoordinator(rootViewController: self)
        let hostingController = UIHostingController(
            rootView: AddSourceView(externalSources: viewModel.unfilteredExternalSources)
                .ignoresSafeArea() // fixes some weird keyboard clipping stuff
                .environmentObject(path)
        )
        path.rootViewController = hostingController
        if #available(iOS 26.0, *) {
            hostingController.preferredTransition = .zoom { _ in
                self.navigationItem.rightBarButtonItems?.first
            }
        }
        hostingController.modalPresentationStyle = .pageSheet
        present(hostingController, animated: true)
    }

    @objc func stopEditing() {
        setEditing(false, animated: true)
    }

    @objc func deleteSelected() {
        confirmAction(
            continueActionName: NSLocalizedString("UNINSTALL"),
            sourceItem: toolbarItems?.first
        ) {
            let sourceKeys = self.tableView.indexPathsForSelectedRows?.compactMap { (path: IndexPath) -> String? in
                guard let item = self.dataSource.itemIdentifier(for: path) else { return nil }
                return item.info.sourceId
            } ?? []
            self.uninstall(sourceKeys: sourceKeys)
        }
    }
}

// MARK: - Table View Delegate
extension BrowseViewController {
    // support two finger drag to select
    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        setEditing(true, animated: true)
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        if isEditing {
            // fix double selection animation when editing
            cell.setHighlighted(false, animated: false)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let sectionId = dataSource.sectionIdentifier(for: indexPath.section)
        guard !isEditing else {
            if !(sectionId?.listsSources ?? false) {
                tableView.deselectRow(at: indexPath, animated: false)
            } else {
                updateToolbar()
            }
            return
        }
        if
            sectionId?.listsSources == true,
            let item = dataSource.itemIdentifier(for: indexPath),
            !item.info.disabled,
            let source = SourceManager.shared.store.source(for: item.info.sourceId)
        {
            let vc: UIViewController = if let legacySource = source.legacySource {
                SourceViewController(source: legacySource)
            } else {
                NewSourceViewController(source: source)
            }
            SourceRecents.record(item.info.sourceId)
            navigationController?.pushViewController(vc, animated: true)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if isEditing {
            updateToolbar()
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard
            let cell = tableView.dequeueReusableHeaderFooterView(
                withIdentifier: String(describing: UITableViewHeaderFooterView.self)
            ),
            let currentSection = dataSource.sectionIdentifier(for: section)
        else {
            return nil
        }
        var config = SmallSectionHeaderConfiguration()
        switch currentSection {
            case .updates:
                config.title = NSLocalizedString("UPDATES")
            case .pinned:
                config.title = NSLocalizedString("PINNED")
            case .recent:
                config.title = NSLocalizedString("RECENTLY_USED")
            case let .language(code):
                config.title = SourceLanguage.displayName(for: code)
            case .external:
                config.title = NSLocalizedString("EXTERNAL")
        }
        cell.contentConfiguration = config
        return cell
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            !tableView.isEditing, // do not allow context menu when the sources are being edited
            case let section = dataSource.sectionIdentifier(for: indexPath.section),
            let section,
            section.listsSources,
            let item = dataSource.itemIdentifier(for: indexPath)
        else {
            return nil
        }
        let info = item.info
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ -> UIMenu? in
            let editAction = UIMenu(title: "", options: .displayInline, children: [
                UIAction(
                    title: section == .pinned ? NSLocalizedString("REORDER") : NSLocalizedString("EDIT_SOURCES"),
                    image: UIImage(systemName: section == .pinned ? "shuffle" : "minus.circle")
                ) { _ in
                    self.setEditing(true, animated: true)
                }
            ])

            let pinAction = UIAction(
                title: section == .pinned ? NSLocalizedString("UNPIN") : NSLocalizedString("PIN"),
                image: UIImage(systemName: section == .pinned ? "pin.slash" : "pin")
            ) { _ in
                if section == .pinned {
                    SourceManager.shared.unpin(sourceKey: info.sourceId)
                } else {
                    SourceManager.shared.pin(sourceKey: info.sourceId)
                }
            }

            let disableAction = UIAction(
                title: info.disabled ? NSLocalizedString("ENABLE") : NSLocalizedString("DISABLE"),
                image: UIImage(systemName: info.disabled ? "play" : "pause")
            ) { _ in
                Task {
                    if info.disabled {
                        await SourceManager.shared.enable(sourceKey: info.sourceId)
                    } else {
                        await SourceManager.shared.disable(sourceKey: info.sourceId)
                    }
                }
            }

            let uninstallAction = UIAction(
                title: NSLocalizedString("UNINSTALL"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self.uninstall(sourceKeys: [info.sourceId])
            }

            let settingsAction = UIAction(
                title: NSLocalizedString("SOURCE_SETTINGS"),
                image: UIImage(systemName: "gearshape")
            ) { _ in
                self.openSettings(sourceKey: info.sourceId)
            }

            return UIMenu(title: "", children: [
                editAction,
                pinAction,
                settingsAction,
                disableAction,
                uninstallAction
            ])
        }
    }
}

// MARK: - Data Source
extension BrowseViewController {
    enum Section: Hashable {
        case pinned
        case updates
        /// The last sources opened (SUWA-12 B1).
        case recent
        /// The installed sources of a language (SUWA-12 B1).
        case language(String)
        case external

        /// Sections of installed sources (open, pin, edit).
        var listsSources: Bool {
            switch self {
                case .pinned, .recent, .language: true
                case .updates, .external: false
            }
        }
    }

    struct SourceItem: Hashable {
        let section: Section
        let info: SourceInfo

        static func == (lhs: SourceItem, rhs: SourceItem) -> Bool {
            lhs.section == rhs.section && lhs.info.sourceId == rhs.info.sourceId
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(section)
            hasher.combine(info.sourceId)
        }
    }

    private func sourceItems(_ sources: [SourceInfo], in section: Section) -> [SourceItem] {
        var seenSourceIds = Set<String>()
        return sources.compactMap { info in
            guard seenSourceIds.insert(info.sourceId).inserted else { return nil }
            return SourceItem(section: section, info: info)
        }
    }

    // Ability to edit tableview for a diffable data source.
    // Changing data in a diffable data source requires its seperate tableview override which can't be done with the view's tableview delegate.
    class SourceCellDataSource: UITableViewDiffableDataSource<Section, SourceItem> {
        // Used for callback when cells are reordered in the pinned section.
        var onReorder: ((NSDiffableDataSourceSnapshot<Section, SourceItem>) -> Void)?
        // Let the rows in the Pinned section be reordered (used for reordering sources)
        override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
            sectionIdentifier(for: indexPath.section) == .pinned
        }

        // Move a selected source row from pinned section to a destination index.
        override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            guard
                let sourceItem = itemIdentifier(for: sourceIndexPath),
                sourceIndexPath != destinationIndexPath
            else { return }

            let destinationItem = itemIdentifier(for: destinationIndexPath)

            var snapshot = self.snapshot()

            if
                let destinationItem = destinationItem,
                let sourceIndex = snapshot.indexOfItem(sourceItem),
                let destinationIndex = snapshot.indexOfItem(destinationItem)
            {
                snapshot.deleteItems([sourceItem])

                if destinationIndex > sourceIndex {
                    snapshot.insertItems([sourceItem], afterItem: destinationItem)
                } else {
                    snapshot.insertItems([sourceItem], beforeItem: destinationItem)
                }
            }
            // Save the order and notify the observer to reload table.
            apply(snapshot, animatingDifferences: false)
            onReorder?(snapshot)
        }

        override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
            sectionIdentifier(for: indexPath.section)?.listsSources ?? false
        }
    }

    private func makeDataSource() -> SourceCellDataSource {
        // Use subclass of UITableViewDiffableDataSource to add tableview overrides.
        SourceCellDataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            guard
                let self = self,
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: String(describing: SourceTableViewCell.self)
                ) as? SourceTableViewCell,
                let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else {
                return UITableViewCell()
            }

            cell.delegate = self
            cell.setSourceInfo(item.info, section: section)

            return cell
        }
    }

    func updateDataSource() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, SourceItem>()

        if !viewModel.updatesSources.isEmpty {
            snapshot.appendSections([.updates])
            snapshot.appendItems(sourceItems(viewModel.updatesSources, in: .updates), toSection: .updates)
        }
        if !viewModel.pinnedSources.isEmpty {
            snapshot.appendSections([.pinned])
            snapshot.appendItems(sourceItems(viewModel.pinnedSources, in: .pinned), toSection: .pinned)
        }
        // by language, with the last ones used first (SUWA-12 B1)
        let isSearching = !(sourcesSearchController?.searchBar.text ?? "").isEmpty
        let groups = BrowseSourceGroups.make(
            installed: viewModel.installedSources,
            pinnedKeys: Set(viewModel.pinnedSources.map(\.sourceId)),
            recents: SourceRecents.load(),
            active: BrowseLanguages.active(),
            showRecent: !isSearching
        )
        if !groups.recent.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(sourceItems(groups.recent, in: .recent), toSection: .recent)
        }
        for group in groups.languages where !group.sources.isEmpty {
            snapshot.appendSections([.language(group.code)])
            snapshot.appendItems(sourceItems(group.sources, in: .language(group.code)), toSection: .language(group.code))
        }
//        if !viewModel.externalSources.isEmpty {
//            snapshot.appendSections([.external])
//            snapshot.appendItems(viewModel.externalSources, toSection: .external)
//        }

        let isInitialSnapshot = !hasAppliedInitialSnapshot
        hasAppliedInitialSnapshot = true

        if isInitialSnapshot {
            // fade in animation for initial load to avoid jumpy default animation
            tableView.alpha = 0

            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }

                self.tableView.layoutIfNeeded()

                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                    self.tableView.alpha = 1
                }
            }
        } else {
            let previousItems = dataSource.snapshot().itemIdentifiers
            let changedItems = snapshot.itemIdentifiers.filter { item in
                guard let previous = previousItems.first(where: { $0 == item }) else {
                    return false
                }
                return previous.info != item.info
            }
            snapshot.reconfigureItems(changedItems)

            dataSource.apply(snapshot)
        }

        Task { @MainActor in
            if sourcesSearchController?.searchBar.text?.isEmpty ?? true {
                emptyStackView.isHidden = !snapshot.itemIdentifiers.isEmpty || tabControl.selectedSegmentIndex != 0
            }
            checkUpdateCount()
        }
    }

    func updateExternalSources() {
        var snapshot = dataSource.snapshot()

        snapshot.deleteSections([.updates, .external])
        if !viewModel.updatesSources.isEmpty {
            if snapshot.indexOfSection(.pinned) != nil {
                snapshot.insertSections([.updates], beforeSection: .pinned)
            } else if let first = snapshot.sectionIdentifiers.first(where: { $0.listsSources }) {
                snapshot.insertSections([.updates], beforeSection: first)
            } else {
                snapshot.appendSections([.updates])
            }
            snapshot.appendItems(sourceItems(viewModel.updatesSources, in: .updates), toSection: .updates)
        }
//        if !viewModel.externalSources.isEmpty {
//            snapshot.appendSections([.external])
//            snapshot.appendItems(viewModel.externalSources, toSection: .external)
//        }

        // prevents jumpiness from pull to refresh
        dataSource.apply(snapshot)

        Task { @MainActor in
            emptyStackView.isHidden = !snapshot.itemIdentifiers.isEmpty || tabControl.selectedSegmentIndex != 0
            checkUpdateCount()
        }
    }
}

// MARK: - Search Results
extension BrowseViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.search(query: searchController.searchBar.text)
        updateDataSource()
    }
}

extension BrowseViewController {
    func updateNavbar(isEditing: Bool? = nil) {
        let isEditing = isEditing ?? self.isEditing
        if isEditing {
            navigationItem.rightBarButtonItems = [UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(stopEditing)
            )]
        } else {
            let addSourceBarButton = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                style: .plain,
                target: self,
                action: #selector(openAddSourcePage)
            )
            addSourceBarButton.title = NSLocalizedString("ADD_SOURCE")
            if #available(iOS 26.0, *) {
                addSourceBarButton.sharesBackground = false
            }

            let languagesBarButton = UIBarButtonItem(
                image: UIImage(systemName: "character.book.closed"),
                style: .plain,
                target: self,
                action: #selector(openLanguages)
            )
            languagesBarButton.title = NSLocalizedString("LANGUAGES")
            languagesBarButton.accessibilityLabel = NSLocalizedString("LANGUAGES")
            if #available(iOS 26.0, *) {
                languagesBarButton.sharesBackground = false
            }

            navigationItem.rightBarButtonItems = tabControl.selectedSegmentIndex == 0
                ? [addSourceBarButton, languagesBarButton]
                : [languagesBarButton]
        }
    }

    func updateToolbar(isEditing: Bool? = nil) {
        let isEditing = isEditing ?? self.isEditing
        if isEditing {
            // show toolbar
            if navigationController?.isToolbarHidden ?? false {
                UIView.animate(withDuration: CATransaction.animationDuration()) {
                    self.navigationController?.isToolbarHidden = false
                    self.navigationController?.toolbar.alpha = 1
                    if #available(iOS 26.0, *) {
                        // hide tab bar on iOS 26 (it covers the toolbar)
                        self.tabBarController?.isTabBarHidden = true
                    }
                }
            }
            // enable items
            let hasSelectedItems = !(tableView.indexPathsForSelectedRows?.isEmpty ?? true)
            toolbarItems?.first?.isEnabled = hasSelectedItems
        } else if !(self.navigationController?.isToolbarHidden ?? true) {
            // fade out toolbar
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.navigationController?.toolbar.alpha = 0
                if #available(iOS 26.0, *) {
                    // reshow tab bar on iOS 26
                    self.tabBarController?.isTabBarHidden = false
                }
            } completion: { _ in
                self.navigationController?.isToolbarHidden = true
            }
        }
    }
}

extension BrowseViewController: @MainActor SourceCellDelegate {
    func getButtonPressed(cell: SourceTableViewCell) {
        guard
            let externalInfo = cell.info?.externalInfo,
            let url = externalInfo.fileURL
        else {
            cell.getButton.buttonState = .fail
            return
        }
        cell.getButton.buttonState = .downloading
        Task {
            let installedSource = await SourceManager.shared.importSource(from: url)
            cell.getButton.buttonState = installedSource == nil ? .fail : .get
        }
    }

    func warningButtonPressed(cell: SourceTableViewCell) {
        let alert = UIAlertController(
            title: NSLocalizedString("MISSING_SOURCE_LIST"),
            message: NSLocalizedString("MISSING_SOURCE_LIST_INFO"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .cancel) { _ in })
        present(alert, animated: true)
    }
}

// MARK: - SUWA-12: tabs, languages, pin and settings
extension BrowseViewController {
    @objc func tabChanged() {
        let index = tabControl.selectedSegmentIndex
        if isEditing {
            setEditing(false, animated: false)
        }
        for (key, child) in tabChildren {
            child.view.isHidden = key != index
        }
        tableView.isHidden = index != 0
        navigationItem.searchController = index == 0 ? sourcesSearchController : nil
        if index == 0 {
            emptyStackView.isHidden = !dataSource.snapshot().itemIdentifiers.isEmpty
        } else {
            emptyStackView.isHidden = true
            showTab(index)
        }
        updateNavbar()
    }

    private func showTab(_ index: Int) {
        guard tabChildren[index] == nil else { return }
        let path = NavigationCoordinator(rootViewController: self)
        let child: UIViewController = index == 1
            ? UIHostingController(rootView: ServerExtensionsView().environmentObject(path))
            : UIHostingController(rootView: MigrateSourcesView(embedded: true).environmentObject(path))
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(child.view, belowSubview: tabHeader)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: tabHeader.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
        tabChildren[index] = child
    }

    @objc func openLanguages() {
        let viewController = SwiftUINavigationViewController(rootView: BrowseLanguagesView())
        viewController.modalPresentationStyle = .pageSheet
        present(viewController, animated: true)
    }

    func openSettings(sourceKey: String) {
        guard let source = SourceManager.shared.store.source(for: sourceKey) else { return }
        let viewController = SwiftUINavigationViewController(rootView: SourceSettingsView(source: source))
        viewController.modalPresentationStyle = .pageSheet
        present(viewController, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard
            !tableView.isEditing,
            let section = dataSource.sectionIdentifier(for: indexPath.section),
            section.listsSources,
            let item = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        let isPinned = section == .pinned
        let pin = UIContextualAction(
            style: .normal,
            title: NSLocalizedString(isPinned ? "UNPIN" : "PIN")
        ) { _, _, done in
            if isPinned {
                SourceManager.shared.unpin(sourceKey: item.info.sourceId)
            } else {
                SourceManager.shared.pin(sourceKey: item.info.sourceId)
            }
            done(true)
        }
        pin.image = UIImage(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
        pin.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [pin])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard
            !tableView.isEditing,
            let section = dataSource.sectionIdentifier(for: indexPath.section),
            section.listsSources,
            let item = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        let settings = UIContextualAction(style: .normal, title: NSLocalizedString("SOURCE_SETTINGS")) { _, _, done in
            self.openSettings(sourceKey: item.info.sourceId)
            done(true)
        }
        settings.image = UIImage(systemName: "gearshape.fill")
        settings.backgroundColor = .systemGray
        return UISwipeActionsConfiguration(actions: [settings])
    }
}

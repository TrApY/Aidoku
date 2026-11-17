//
//  ReaderViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/14/22.
//

import AidokuRunner
import SafariServices
import SwiftUI
import UIKit

class ReaderViewController: BaseObservingViewController {
    enum Reader {
        case paged
        case scroll
        case text
    }

    let source: AidokuRunner.Source?
    let manga: AidokuRunner.Manga
    var chapter: AidokuRunner.Chapter
    var pages: [Page] = []
    var readingMode: ReadingMode = .rtl
    var defaultReadingMode: ReadingMode?
    private var tapZone: TapZone?
    private let temporaryPageStore = ReaderTemporaryPageStore()

    private var chapterList: [AidokuRunner.Chapter]
    private var chaptersToMark: [AidokuRunner.Chapter] = []
    /// How the reader saw the end of the chapter, for the completion journal (SUWA-12 F).
    private var completionTrigger = "lector"
    private var chaptersToRemoveDownload: [AidokuRunner.Chapter] = [] {
        didSet {
            // ensure chapters queued for deletion are persistent, in case of app termination
            if chaptersToRemoveDownload.isEmpty {
                UserDefaults.standard.removeObject(forKey: "Data.chaptersToBeDeleted")
            } else {
                let data = try? JSONEncoder().encode(chaptersToRemoveDownload.map {
                    ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
                })
                UserDefaults.standard.set(data, forKey: "Data.chaptersToBeDeleted")
            }
        }
    }
    /// The chapters whose last page the user reached in this reader, with the app in front: changing chapter
    /// completes only the chapter being read, and only if it is one of these (SUWA-17 C1).
    private var lastPageSeenChapters: Set<String> = []
    /// The chapters this reader already tried to complete: once each (entering the transition and then going
    /// on to the next chapter is one completion, not two; SUWA-17 C2).
    private var completionAttempted: Set<String> = []
    /// The chapter was entered from below by scrolling (the reader went back up into it from the next one): nothing
    /// of it is saved or completed until the user goes up into its pages (SUWA-17 D4, D5). Opening a chapter
    /// (loadCurrentChapter: the chapter list, the buttons) is not entering it from below.
    private var enteredFromBelow = false
    private var forceStartPage: Int?
    private(set) var currentPage = 1
    /// The app in front (page changes and completions only then). Replaced in tests. SUWA-12 I1
    lazy var appActivity = ReaderAppActivity(active: UIApplication.shared.applicationState == .active)
    private var currentPosition: Double?
    private var sessionReadPages: Set<Int> = []
    private var sessionStartDate: Date?
    private var sessionLastInteraction: Date?

    /// What a delayed save of the reading position needs.
    private struct ReadPosition: ReadPositionKeyed {
        let chapter: AidokuRunner.Chapter
        let page: Int
        let totalPages: Int
        let scrollPosition: Double?

        var pageKey: String { Self.pageKey(chapter: chapter, page: page, position: scrollPosition) }
        var trackerKey: String { Self.pageKey(chapter: chapter, page: page, position: nil) }

        static func pageKey(chapter: AidokuRunner.Chapter, page: Int, position: Double?) -> String {
            ReadPositionKey.make(chapterKey: chapter.key, page: page, position: position)
        }
    }

    /// Saves the page while reading (locally after ~2 s, page trackers after ~30 s), so it isn't lost
    /// if the app is killed without leaving the reader.
    private lazy var readPositionSaver = ReadPositionSaver<ReadPosition>(
        isEnabled: { !AppSettings.general.incognitoMode.get() },
        saveLocal: { [weak self] position, generation in
            Task {
                await self?.updateReadPosition(
                    currentPage: position.page,
                    totalPages: position.totalPages,
                    chapter: position.chapter,
                    scrollPosition: position.scrollPosition,
                    updateTrackers: false,
                    saveSession: false,
                    generation: generation,
                    pageKey: position.pageKey
                )
            }
        },
        saveTracker: { [weak self] position, generation in
            Task {
                await self?.updateTrackerProgress(
                    page: position.page,
                    chapter: position.chapter,
                    generation: generation,
                    pageKey: position.trackerKey
                )
            }
        }
    )

    weak var reader: ReaderReaderDelegate?

    // Dictionary popup state
    private lazy var dictionaryCoordinator = ReaderDictionaryCoordinator(owner: self)
    private var _dictionaryLongPressSelection: Any?
    private var dictionaryLongPressSelection: TextRecognizer.Result? {
        get { _dictionaryLongPressSelection as? TextRecognizer.Result }
        set { _dictionaryLongPressSelection = newValue }
    }
    private var isDictionaryOCRActiveForCurrentChapter: Bool {
        AppSettings.dictionary.isOCREnabled(language: chapter.language ?? source?.languages.first)
    }
    private var isDictionarySingleTapLookupActiveForCurrentChapter: Bool {
        AppSettings.dictionary.lookupGesture.get() == .singleTap && isDictionaryOCRActiveForCurrentChapter
    }
    private var isDictionaryLongPressLookupActiveForCurrentChapter: Bool {
        AppSettings.dictionary.lookupGesture.get() == .longPress && isDictionaryOCRActiveForCurrentChapter
    }

    private lazy var activityIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var toolbarView = ReaderToolbarView()
    private var toolbarViewWidthConstraint: NSLayoutConstraint?

    private var squeezeTimer: Timer?
    private var longSqueezeTimer: Timer?
    private var squeezeStartTime: Date?
    private let doubleSqueezeInterval: TimeInterval = 0.3
    private let longSqueezeThreshold: TimeInterval = 0.5

    private lazy var autoScrollButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration = .glass()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "play.fill")
        configuration.contentInsets = .init(top: 10, leading: 10, bottom: 10, trailing: 10)

        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(toggleAutoScroll), for: .touchUpInside)
        button.addTarget(self, action: #selector(autoScrollButtonTouchDown), for: .touchDown)
        button.addTarget(
            self,
            action: #selector(autoScrollButtonTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()
    private var isInteractingWithAutoScrollButton = false
    private lazy var autoScrollButtonLeadingConstraint =
        autoScrollButton.leadingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.leadingAnchor,
            constant: 16
        )
    private lazy var autoScrollButtonTrailingConstraint =
        autoScrollButton.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: -16
        )

    private lazy var descriptionButtonController: UIHostingController<ReaderPageDescriptionButtonView> = {
        let buttonView = ReaderPageDescriptionButtonView(source: source, pages: [])
        let hostingController = UIHostingController(rootView: buttonView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.alpha = 0
        hostingController.view.isHidden = true
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        return hostingController
    }()
    private lazy var descriptionTrailingConstraint =
        descriptionButtonController.view.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: -16
        )
    private lazy var descriptionTrailingToAutoScrollConstraint =
        descriptionButtonController.view.trailingAnchor.constraint(
            equalTo: autoScrollButton.leadingAnchor,
            constant: -16
        )

    private var barToggleTapGesture: UITapGestureRecognizer?
    private var barToggleSecondaryTapGesture: UITapGestureRecognizer?
    private var barDismissNavigationBarTapGesture: UITapGestureRecognizer?
    private var dictionaryLongPressGesture: UILongPressGestureRecognizer?

    var statusBarHidden = false

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        UIStatusBarAnimation.fade
    }
    override var prefersStatusBarHidden: Bool {
        statusBarHidden
    }
    override var prefersHomeIndicatorAutoHidden: Bool {
        statusBarHidden
    }

    init(
        source: AidokuRunner.Source?,
        manga: AidokuRunner.Manga,
        chapter: AidokuRunner.Chapter,
        startPage: Int? = nil
    ) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
        self.chapterList = manga.chapters ?? []
        self.chaptersToMark = [chapter]
        self.defaultReadingMode = switch manga.viewer {
            case .rightToLeft: .rtl
            case .leftToRight: .ltr
            case .vertical: .vertical
            case .webtoon: .webtoon
            case .unknown: .none
        }
        self.forceStartPage = startPage
        super.init()
    }

    deinit {
        Task { [temporaryPageStore] in
            await temporaryPageStore.removeAll()
        }
    }

    override func configure() {
        node.backgroundColor = .systemBackground
        navigationController?.navigationBar.prefersLargeTitles = false

        // navbar buttons
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(close)
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "list.bullet"),
                style: .plain,
                target: self,
                action: #selector(openChapterList)
            )
        ]
        let moreButton = UIBarButtonItem(
            image: UIImage(systemName: "safari"),
            style: .plain,
            target: self,
            action: #selector(openWebView)
        )
        moreButton.isEnabled = chapter.url != nil
        navigationItem.rightBarButtonItems = [
            moreButton,
            UIBarButtonItem(
                image: UIImage(systemName: "textformat.size"),
                style: .plain,
                target: self,
                action: #selector(openReaderSettings)
            )
        ]

        // fix navbar being clear
        let navigationBarAppearance = UINavigationBarAppearance()
        let toolbarAppearance = UIToolbarAppearance()
        navigationBarAppearance.configureWithDefaultBackground()
        toolbarAppearance.configureWithDefaultBackground()
        navigationController?.navigationBar.standardAppearance = navigationBarAppearance
        navigationController?.navigationBar.compactAppearance = navigationBarAppearance
        navigationController?.navigationBar.scrollEdgeAppearance = navigationBarAppearance
        navigationController?.toolbar.standardAppearance = toolbarAppearance
        navigationController?.toolbar.compactAppearance = toolbarAppearance
        navigationController?.toolbar.scrollEdgeAppearance = toolbarAppearance

        loadNavbarTitle()

        // toolbar view
        toolbarView.sliderView.addTarget(self, action: #selector(sliderMoved(_:)), for: .valueChanged)
        toolbarView.sliderView.addTarget(self, action: #selector(sliderStopped(_:)), for: .editingDidEnd)
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        let toolbarButtonItemView = UIBarButtonItem(customView: toolbarView)
        toolbarButtonItemView.customView?.heightAnchor.constraint(equalToConstant: 40).isActive = true
        toolbarViewWidthConstraint = toolbarButtonItemView.customView?.widthAnchor.constraint(
            equalToConstant: node.bounds.width - 32 - 10
        )
        // shift down farther to account for different toolbar and slider knob size
        toolbarButtonItemView.customView?.transform = CGAffineTransform(translationX: 0, y: -5)

        add(child: descriptionButtonController)
        view.addSubview(autoScrollButton)

        toolbarItems = [toolbarButtonItemView]
        navigationController?.isToolbarHidden = false
        navigationController?.toolbar.fitContentViewToToolbar()

        // loading indicator
        activityIndicator.startAnimating()
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        // initialize dictionary engine
        if
            AppSettings.dictionary.enable.get()
                {
            DictionaryManager.shared.rebuildLookupQuery()
        }
        configureDictionaryLookupGesture()
        configureDictionaryOverlayInteractionMode()

        // bar toggle tap gesture
        configureBarToggleTapGestures()

        // page offset tap gesture
        let pageOffsetGesture = UITapGestureRecognizer(target: self, action: #selector(toggleOffset))
        pageOffsetGesture.numberOfTouchesRequired = 2
        pageOffsetGesture.numberOfTapsRequired = 2
        view.addGestureRecognizer(pageOffsetGesture)

        // set reader
        let readingModeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.register(defaults: [readingModeKey: "default"])
        setReadingMode(UserDefaults.standard.string(forKey: readingModeKey))

        // set up apple pencil squeeze handler
        let pencilInteraction = UIPencilInteraction(delegate: self)
        view.addInteraction(pencilInteraction)

        // load current tap zone
        updateTapZone()

        // load chapter list
        loadCurrentChapter()
    }

    override func constrain() {
        toolbarViewWidthConstraint?.isActive = true

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            descriptionButtonController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            autoScrollButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        updateAutoScrollButton()
    }

    override func observe() {
        addObserver(forName: "Reader.readingMode.\(manga.identifier)") { [weak self] _ in
            guard let self else { return }
            self.setReadingMode(UserDefaults.standard.string(forKey: "Reader.readingMode.\(self.manga.identifier)"))
            self.reader?.setChapter(self.chapter, startPage: self.currentPage)
            // if the tap zone is auto, it will changed based on the current reader
            self.updateTapZone()
        }
        addObserver(forName: "Reader.disableDoubleTap") { [weak self] _ in
            self?.configureBarToggleTapGestures()
        }
        addObserver(forName: "Reader.autoScroll") { [weak self] _ in
            self?.updateAutoScrollButton()
        }
        addObserver(forName: .readerTapZones) { [weak self] _ in
            self?.updateTapZone()
        }
        let reloadBlock: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.reader?.setChapter(self.chapter, startPage: self.currentPage)
        }
        // reload pages when processors change
        addObserver(forName: "Reader.downsampleImages", using: reloadBlock)
        addObserver(forName: "Reader.upscaleImages", using: reloadBlock)
        addObserver(forName: AppSettings.reader.upscaleQuality.key, using: reloadBlock)
        addObserver(forName: "Reader.cropBorders", using: reloadBlock)
        addObserver(forName: "Reader.liveText", using: reloadBlock)
        addObserver(forName: AppSettings.dictionary.overlayPadding.key, using: reloadBlock)
        addObserver(forName: AppSettings.dictionary.overlayTextScaleMultiplier.key, using: reloadBlock)
        let dictionaryReloadBlock: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.configureBarToggleTapGestures()
            self.configureDictionaryLookupGesture()
            self.configureDictionaryOverlayInteractionMode()
            self.reader?.setChapter(self.chapter, startPage: self.currentPage)
        }
        for key in [
            AppSettings.dictionary.enable.key,
            AppSettings.dictionary.lookupGesture.key,
            AppSettings.dictionary.textOverlayMode.key,
            AppSettings.dictionary.restrictOCRLanguages.key,
            AppSettings.dictionary.restrictedOCRLanguages.key
        ] {
            addObserver(forName: key, using: dictionaryReloadBlock)
        }
        addObserver(forName: .dictionaryDictionariesChanged, using: dictionaryReloadBlock)
        // Switch text reader style (paged <-> scroll) without restart
        addObserver(forName: "Reader.textReaderStyle") { [weak self] _ in
            guard let self else { return }
            // Only switch if we're currently in a text reader
            if self.reader is ReaderTextViewController || self.reader is ReaderPagedTextViewController {
                // Save current position before switching so the new reader can restore it
                Task {
                    await self.updateReadPosition()
                    await MainActor.run {
                        self.setReader(.text)
                        self.reader?.setChapter(self.chapter, startPage: self.currentPage)
                        self.updateTapZone()
                    }
                }
            }
        }
        addObserver(forName: ReaderTextTheme.changeNotification) { [weak self] _ in
            self?.updateTextThemeOverride()
        }
        addObserver(forName: UIScene.willDeactivateNotification) { [weak self] _ in
            guard let self else { return }
            self.saveReadPositionNow()

            statusBarHidden = false
        }
        addObserver(forName: UIScene.didEnterBackgroundNotification) { [weak self] _ in
            self?.saveReadPositionNow()
        }
        addObserver(forName: UIScene.didActivateNotification) { [weak self] _ in
            guard let self else { return }
            if self.sessionStartDate == nil {
                self.sessionReadPages = [self.currentPage]
                self.sessionStartDate = Date.now
                self.sessionLastInteraction = nil
            }
        }
        addObserver(forName: UIScene.willEnterForegroundNotification) { [weak self] _ in
            if self?.navigationController?.toolbar.alpha == 0 {
                self?.hideBars()
            }
        }
        addObserver(forName: "Reader.autoScroll") { [weak self] _ in
            self?.updateAutoScrollButton()
        }
        addObserver(forName: AppSettings.reader.autoScrollPosition.key) { [weak self] _ in
            guard let self else { return }
            let visible = self.reader is ReaderWebtoonViewController && UserDefaults.standard.bool(forKey: "Reader.autoScroll")
            self.updateAutoScrollButtonPosition(visible: visible, animated: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        sessionReadPages = [self.currentPage]
        sessionStartDate = Date.now
        sessionLastInteraction = nil

        if navigationController?.toolbar.alpha == 0 {
            hideBars()
        }

        // there's a bug on ios 15 where the toolbar just disappears when adding a child hosting controller
        navigationController?.isToolbarHidden = false
        navigationController?.toolbar.alpha = 1

        disableSwipeGestures()
        configureNavigationBarDismissTapGesture(enabled: isDictionarySingleTapLookupActiveForCurrentChapter)

        // resume auto scroll if it was paused when presenting a sheet
        if let reader = reader as? ReaderWebtoonViewController {
            reader.resumeAutoScroll()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        (reader as? ReaderWebtoonViewController)?.stopAutoScroll()

        if !chaptersToRemoveDownload.isEmpty {
            Task {
                await DownloadManager.shared.delete(chapters: chaptersToRemoveDownload.map {
                    .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
                })
                chaptersToRemoveDownload = []
            }
        }

        // nothing of a chapter entered from below and not gone up into (SUWA-17 D4)
        guard currentPage >= 1, !enteredFromBelow else {
            readPositionSaver.cancel()
            return
        }
        // only a page the user moved to and that is not saved yet: the opening page (or one already saved) is not
        // written again, so leaving does not write over a newer page another device saved (iCloud; SUWA-17 D3)
        let needsSave = readPositionSaver.claimImmediateSave(
            pageKey: ReadPosition.pageKey(chapter: chapter, page: currentPage, position: currentPosition),
            trackerKey: ReadPosition.pageKey(chapter: chapter, page: currentPage, position: nil)
        )
        Task {
            if needsSave {
                await updateReadPosition()
            } else if !AppSettings.general.incognitoMode.get() {
                await saveReadingSession()
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: nil) { _ in
            self.toolbarViewWidthConstraint?.constant = size.width - 32 - 10
        }
    }
}

extension ReaderViewController {
    func disableSwipeGestures() {
        let isVerticalReader = reader is ReaderWebtoonViewController || readingMode == .vertical

        // the view with the target gesture recognizers changes based on if it was presented from uikit or swiftui
        let gestureRecognizers = (parent?.view.gestureRecognizers ?? []) + (parent?.view.superview?.superview?.gestureRecognizers ?? [])

        for recognizer in gestureRecognizers {
            switch String(describing: type(of: recognizer)) {
                case "_UIParallaxTransitionPanGestureRecognizer": // swipe edge gesture
                    recognizer.isEnabled = isVerticalReader

                case "_UIContentSwipeDismissGestureRecognizer": // swipe down gesture
                    recognizer.isEnabled = !isVerticalReader
                    recognizer.delegate = self // ensure gesture only activates on swipe down, not swipe right

//                case "_UITransformGestureRecognizer": // pinch gesture
//                    recognizer.isEnabled = true

                default:
                    break
            }
        }
    }

    /// Saves the position now (local + page trackers, awaited), even if the app goes to the background.
    /// Deactivating and then going to the background save once: the second notice finds the page saved.
    /// Returns the task that saves inside the background task (nil if there was nothing to save).
    @discardableResult
    func saveReadPositionNow() -> Task<Void, Never>? {
        let page = currentPage
        let chapter = chapter
        let needsSave = readPositionSaver.claimImmediateSave(
            pageKey: ReadPosition.pageKey(chapter: chapter, page: page, position: currentPosition),
            trackerKey: ReadPosition.pageKey(chapter: chapter, page: page, position: nil)
        )
        let needsSession = sessionStartDate != nil && !AppSettings.general.incognitoMode.get()
        guard needsSave || needsSession else { return nil }
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Reader.saveReadPosition") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        return Task {
            if needsSave {
                await updateReadPosition(currentPage: page, chapter: chapter, updateTrackers: false)
                await updateTrackerProgress(page: page, chapter: chapter)
            } else {
                await saveReadingSession(chapter: chapter)
            }
            // the page tracker update goes out before the background time ends
            await TrackerManager.shared.waitForPendingPageUpdates()
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    /// Sends the page to the page trackers, if the chapter has history and isn't completed.
    /// - generation: for a delayed update, dropped if the saver moved on meanwhile.
    private func updateTrackerProgress(
        page: Int,
        chapter: AidokuRunner.Chapter,
        generation: Int? = nil,
        pageKey: String? = nil
    ) async {
        guard !AppSettings.general.incognitoMode.get(), page >= 1 else { return }
        let chapterId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        let stored = await DataRepositories.shared.history.progress(of: chapterId)
        guard !stored.completed, stored.progress != nil else { return }
        if let generation, !readPositionSaver.isCurrent(generation) {
            if let pageKey { readPositionSaver.discarded(pageKey: pageKey, generation: generation) }
            return
        }
        await TrackerManager.shared.setProgress(
            mangaId: chapterId.mangaIdentifier,
            chapter: chapter,
            progress: .init(completed: false, page: page)
        )
    }

    /// - updateTrackers: false for the delayed local save (trackers get their own delayed update).
    /// - saveSession: false for the delayed save (reading sessions are saved as before).
    func updateReadPosition(
        currentPage: Int? = nil,
        totalPages: Int? = nil,
        chapter: AidokuRunner.Chapter? = nil,
        scrollPosition: Double? = nil,
        updateTrackers: Bool = true,
        saveSession: Bool = true,
        generation: Int? = nil,
        pageKey: String? = nil
    ) async {
        let effectiveTotalPages = totalPages ?? toolbarView.totalPages ?? 0
        let effectiveCurrentPage = currentPage ?? self.currentPage

        guard
            !AppSettings.general.incognitoMode.get(),
            effectiveTotalPages > 0 // ensure chapter pages are loaded
        else {
            return
        }

        let currentPage = effectiveCurrentPage
        let chapter = chapter ?? self.chapter

        let chapterId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        let stored = await DataRepositories.shared.history.progress(of: chapterId)
        let (completed, progress) = (stored.completed, stored.progress)
        let hasHistory = completed || progress != nil

        // don't add history if there is none and we're at the first page
        if currentPage == 1 && !hasHistory {
            return
        }

        // a delayed save that started before the position was saved right away (or the chapter changed)
        if let generation, !readPositionSaver.isCurrent(generation) {
            if let pageKey { readPositionSaver.discarded(pageKey: pageKey, generation: generation) }
            return
        }

        await HistoryManager.shared.setProgress(
            chapterId: chapterId,
            chapter: chapter,
            progress: currentPage,
            totalPages: totalPages,
            scrollPosition: scrollPosition ?? currentPosition,
            completed: completed,
            updateTrackers: updateTrackers
        )
        if saveSession {
            await saveReadingSession(chapter: chapter)
        }
    }

    private func saveReadingSession(chapter: AidokuRunner.Chapter? = nil) async {
        guard let sessionStartDate else { return }
        // cleared before awaiting, so a second call meanwhile (deactivate + background) can't save it again
        self.sessionStartDate = nil
        let pagesRead = sessionReadPages.count
        if pagesRead > 0 && sessionLastInteraction != nil {
            let chapter = chapter ?? self.chapter
            await HistoryManager.shared.addSession(
                chapterId: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key),
                data: .init(startDate: sessionStartDate, endDate: .now, pagesRead: pagesRead)
            )
        }
    }

    func loadChapterList() async {
        let updatedManga = try? await source?.getMangaUpdate(
            manga: manga,
            needsDetails: false,
            needsChapters: true
        )
        chapterList = updatedManga?.chapters ?? []
    }

    /// Where the chapter starts, as the reader will report it: the stored page (the first one without
    /// history or when completed) and, for text readers, the stored scroll position.
    private func openingPageKey() -> String {
        let isTextReader = reader is ReaderTextViewController || reader is ReaderPagedTextViewController
        var storedPosition: Double?
        if isTextReader, currentPage >= 1 {
            let history = DataRepositories.shared.mainActorReads.record(
                of: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
            )
            // only the position stored for the page it opens at (not for a completed chapter, unless it is being
            // read again: SUWA-17 D2)
            if let history, !history.completed || Self.isRereading(history), history.progress == currentPage {
                storedPosition = history.scrollPosition
            }
        }
        return ReadPositionKey.opening(
            chapterKey: chapter.key,
            startPage: currentPage,
            isTextReader: isTextReader,
            storedPosition: storedPosition
        )
    }

    /// A completed chapter with a page before its last one: completing leaves it at its last page, so the user
    /// is reading it again (SUWA-17 D2).
    static func isRereading(_ record: HistoryRecord) -> Bool {
        record.completed && record.progress > 0 && record.progress < record.total
    }

    func loadCurrentChapter() {
        enteredFromBelow = false
        if chapterList.isEmpty {
            Task {
                await loadChapterList()
            }
        }

        if let forceStartPage {
            currentPage = forceStartPage
            self.forceStartPage = nil
        } else {
            let stored = DataRepositories.shared.mainActorReads.progress(
                of: .init(
                    sourceKey: manga.sourceKey,
                    mangaKey: manga.key,
                    chapterKey: chapter.key
                )
            )
            let (completed, startPage) = (stored.completed, stored.progress)
            if !completed, let startPage {
                currentPage = startPage
            } else if
                completed,
                let record = DataRepositories.shared.mainActorReads.record(
                    of: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
                ),
                Self.isRereading(record)
            {
                // a completed chapter being read again: where it was left (SUWA-17 D2)
                currentPage = record.progress
            } else {
                currentPage = -1
            }
        }
        // the page it opens at is not a change: nothing is saved until the user turns a page
        readPositionSaver.chapterOpened(
            pageKey: openingPageKey(),
            trackerKey: ReadPosition.pageKey(chapter: chapter, page: max(1, currentPage), position: nil)
        )
        reader?.setChapter(chapter, startPage: currentPage)
    }

    func loadNavbarTitle() {
        let volume: String? =
            if chapter.chapterNumber != nil, let volumeNum = chapter.volumeNumber {
                String(format: NSLocalizedString("VOLUME_X"), volumeNum)
            } else {
                nil
            }

        let title =
            if let chapterNum = chapter.chapterNumber {
                String(format: NSLocalizedString("CHAPTER_X"), chapterNum)
            } else if let volumeNum = chapter.volumeNumber {
                String(format: NSLocalizedString("VOLUME_X"), volumeNum)
            } else {
                chapter.title ?? ""
            }

        navigationItem.setTitle(upper: volume, lower: title)
        // re-apply theme title colors, since setTitle recreates the title view
        updateTextThemeOverride()
    }

    func showLoadFailAlert() {
        let alert = UIAlertController(
            title: NSLocalizedString("FAILED_CHAPTER_LOAD"),
            message: NSLocalizedString("FAILED_CHAPTER_LOAD_INFO"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .cancel))
        present(alert, animated: true)
    }

    @objc func openReaderSettings() {
        (reader as? ReaderWebtoonViewController)?.stopAutoScroll()

        let currentReader: Reader
        switch reader {
            case is ReaderTextViewController, is ReaderPagedTextViewController:
                currentReader = .text
            case is ReaderPagedViewController:
                currentReader = .paged
            case is ReaderWebtoonViewController:
                currentReader = .scroll
            default:
                currentReader = .paged
        }
        let vc = UIHostingController(
            rootView: ReaderSettingsView(
                mangaId: manga.identifier,
                reader: currentReader,
                chapterLanguage: chapter.language ?? source?.languages.first
            )
        )
        if currentReader == .text {
            vc.overrideUserInterfaceStyle = ReaderTextTheme.getInterfaceStyleOverride()
        }
        present(vc, animated: true)
    }

    @objc func openWebView() {
        guard let url = chapter.url, url.scheme == "http" || url.scheme == "https" else { return }
        (reader as? ReaderWebtoonViewController)?.stopAutoScroll()
        present(SFSafariViewController(url: url), animated: true)
    }

    @objc func openChapterList() {
        (reader as? ReaderWebtoonViewController)?.stopAutoScroll()

        var view = ReaderChapterListView(
            chapterList: chapterList,
            chapter: chapter
        )
        view.chapterSet = { [weak self] chapter in
            guard let self else { return }
            if chapter != self.chapter {
                self.setChapter(chapter)
                self.loadCurrentChapter()
            }
        }
        present(UIHostingController(rootView: view), animated: true)
    }

    @objc func close() {
        Task {
            await temporaryPageStore.removeAll()
        }
        dismiss(animated: true)
    }

    @objc func sliderMoved(_ sender: ReaderSliderView) {
        reader?.sliderMoved(value: sender.currentValue)
    }
    @objc func sliderStopped(_ sender: ReaderSliderView) {
        reader?.sliderStopped(value: sender.currentValue)
    }
}

// MARK: - Reading Mode
extension ReaderViewController {
    func setReadingMode(_ mode: String?) {
        switch mode {
            case "rtl": readingMode = .rtl
            case "ltr": readingMode = .ltr
            case "vertical": readingMode = .vertical
            case "scroll", "webtoon": readingMode = .webtoon
            case "continuous": readingMode = .continuous
            case "default":
                let defaultMode = UserDefaults.standard.string(forKey: "Reader.readingMode")
                if defaultMode == "default" {
                    setReadingMode("auto")
                } else {
                    setReadingMode(defaultMode)
                }
                return
            default: // auto
                // use given default reading mode
                if let defaultReadingMode {
                    readingMode = defaultReadingMode
                } else if DataRepositories.shared.mainActorReads.manga(contains: manga.identifier) {
                    // fall back to stored manga viewer
                    let sourceMode = DataRepositories.shared.mainActorReads.readingMode(of: manga.identifier)
                    if let mode = ReadingMode(rawValue: sourceMode) {
                        readingMode = mode
                    } else {
                        readingMode = .rtl
                    }
                } else {
                    // fall back to rtl reading mode
                    readingMode = .rtl
                }
        }

        if !(reader is ReaderTextViewController) {
            switch readingMode {
                case .ltr, .rtl, .vertical:
                    setReader(.paged)
                case .webtoon, .continuous:
                    setReader(.scroll)
            }
        }
    }

    func setReader(_ type: Reader) {
        let pageController: ReaderReaderDelegate?
        switch type {
            case .paged:
                if readingMode == .rtl {
                    toolbarView.sliderView.direction = .backward
                } else {
                    toolbarView.sliderView.direction = .forward
                }
                if !(reader is ReaderPagedViewController) {
                    pageController = ReaderPagedViewController(source: source, manga: manga, temporaryPageStore: temporaryPageStore)
                } else {
                    pageController = nil
                }
            case .scroll:
                toolbarView.sliderView.direction = .forward
                if !(reader is ReaderWebtoonViewController) {
                    pageController = ReaderWebtoonViewController(source: source, manga: manga, temporaryPageStore: temporaryPageStore)
                } else {
                    pageController = nil
                }
            case .text:
                // Text always reads left-to-right, regardless of manga setting
                toolbarView.sliderView.direction = .forward

                // Check user preference for text reader style
                let textReaderStyle = UserDefaults.standard.string(forKey: "Reader.textReaderStyle") ?? "paged"
                if textReaderStyle == "paged" {
                    // Kindle-like paginated experience
                    if !(reader is ReaderPagedTextViewController) {
                        pageController = ReaderPagedTextViewController(source: source, manga: manga)
                    } else {
                        pageController = nil
                    }
                } else {
                    // Original scroll-based text reader
                    if !(reader is ReaderTextViewController) {
                        pageController = ReaderTextViewController(source: source, manga: manga)
                    } else {
                        pageController = nil
                    }
                }
        }
        if let pageController {
            if let webtoonReader = reader as? ReaderWebtoonViewController {
                webtoonReader.stopAutoScroll()
            }
            reader?.remove()
            pageController.delegate = self
            reader = pageController
            add(child: pageController, below: descriptionButtonController.view)
        }
        reader?.readingMode = readingMode
        configureDictionaryOverlayInteractionMode()
        configureDictionaryOverlayTapHandler()
        updateAutoScrollButton()
        disableSwipeGestures()
        updateTextThemeOverride()
    }

    func updateTextThemeOverride() {
        let theme = ReaderTextTheme.getCurrent()
        let isTextReader = reader is ReaderTextViewController || reader is ReaderPagedTextViewController
        let styleOverride: UIUserInterfaceStyle = isTextReader ? ReaderTextTheme.getInterfaceStyleOverride() : .unspecified
        navigationController?.overrideUserInterfaceStyle = styleOverride
        // presented sheets don't inherit the override
        presentedViewController?.overrideUserInterfaceStyle = styleOverride
        let themed = isTextReader && (theme != .default || styleOverride != .unspecified)

        // the bar appearance objects don't follow the trait override,
        // so the theme colors are written into them directly
        let backgroundColor = ReaderTextTheme.getCurrentBackground()
        let textColor = ReaderTextTheme.getCurrentText()
        let titleColor = themed ? textColor : nil
        if let navigationBar = navigationController?.navigationBar {
            func applyTheme(_ appearance: UINavigationBarAppearance) {
                if themed {
                    if reader is ReaderTextViewController {
                        // text scrolls under the bar, so keep it transparent
                        appearance.configureWithTransparentBackground()
                    } else {
                        // nothing extends under the bar, so match the page color
                        appearance.backgroundEffect = nil
                        appearance.backgroundColor = backgroundColor
                        appearance.shadowColor = .clear
                    }
                    appearance.titleTextAttributes[.foregroundColor] = textColor
                } else {
                    appearance.configureWithDefaultBackground()
                    appearance.titleTextAttributes.removeValue(forKey: .foregroundColor)
                }
            }
            let standard = navigationBar.standardAppearance
            applyTheme(standard)
            navigationBar.standardAppearance = standard
            if let compact = navigationBar.compactAppearance {
                applyTheme(compact)
                navigationBar.compactAppearance = compact
            }
            if let scrollEdge = navigationBar.scrollEdgeAppearance {
                applyTheme(scrollEdge)
                navigationBar.scrollEdgeAppearance = scrollEdge
            }
        }
        // the two-line title view (volume + chapter) uses plain labels instead
        if let stackView = navigationItem.titleView as? UIStackView {
            let labels = stackView.arrangedSubviews.compactMap { $0 as? UILabel }
            if labels.count == 2 {
                labels[0].textColor = titleColor?.withAlphaComponent(0.6) ?? .secondaryLabel
                labels[1].textColor = titleColor ?? .label
            }
        }
    }
}

// MARK: - Auto Scroll
extension ReaderViewController {
    @objc private func toggleAutoScroll() {
        guard let webtoonReader = reader as? ReaderWebtoonViewController else { return }
        webtoonReader.toggleAutoScroll()
    }

    private func updateAutoScrollButton() {
        let webtoonReader = reader as? ReaderWebtoonViewController
        let visible = webtoonReader != nil && UserDefaults.standard.bool(forKey: "Reader.autoScroll")

        if !visible {
            webtoonReader?.stopAutoScroll()
        }

        webtoonReader?.onAutoScrollStateChange = { [weak self] _ in
            self?.updateAutoScrollButtonIcon()
        }
        webtoonReader?.onContentScrollingChange = { [weak self] isScrolling in
            self?.setAutoScrollButtonDimmed(isScrolling)
        }

        autoScrollButton.isHidden = !visible
        updateAutoScrollButtonPosition(visible: visible)
        updateAutoScrollButtonIcon()
    }

    private func updateAutoScrollButtonPosition(
        visible: Bool,
        animated: Bool = false
    ) {
        let position = AppSettings.reader.autoScrollPosition.get()
        let isRightAligned = position == .right

        let applyPosition = {
            self.autoScrollButtonLeadingConstraint.isActive = !isRightAligned
            self.autoScrollButtonTrailingConstraint.isActive = isRightAligned

            // when auto scroll button is on the right, the description button needs to be shifted to the left of it
            self.descriptionTrailingConstraint.isActive = !visible || !isRightAligned
            self.descriptionTrailingToAutoScrollConstraint.isActive = visible && isRightAligned
        }

        guard animated else {
            applyPosition()
            return
        }

        view.layoutIfNeeded()
        applyPosition()

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            self.view.layoutIfNeeded()
        }
    }

    private func updateAutoScrollButtonIcon() {
        let isAutoScrolling = (reader as? ReaderWebtoonViewController)?.isAutoScrolling == true
        autoScrollButton.configuration?.image = UIImage(systemName: isAutoScrolling ? "pause.fill" : "play.fill")
    }

    @objc private func autoScrollButtonTouchDown() {
        isInteractingWithAutoScrollButton = true
        setAutoScrollButtonDimmed(false)
    }

    @objc private func autoScrollButtonTouchEnded() {
        isInteractingWithAutoScrollButton = false
        let isScrolling = (reader as? ReaderWebtoonViewController)?.isContentScrolling ?? false
        setAutoScrollButtonDimmed(isScrolling)
    }

    private func setAutoScrollButtonDimmed(_ dimmed: Bool) {
        let alpha: CGFloat = dimmed && !isInteractingWithAutoScrollButton ? 0.5 : 1

        guard autoScrollButton.alpha != alpha else { return }

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            self.autoScrollButton.alpha = alpha
        }
    }
}

// MARK: - Reader Holding Delegate
extension ReaderViewController: @MainActor ReaderHoldingDelegate {
    var barsHidden: Bool { statusBarHidden }

    private func areDuplicates(_ a: AidokuRunner.Chapter, _ b: AidokuRunner.Chapter) -> Bool {
        a.chapterNumber == b.chapterNumber
            && a.volumeNumber == b.volumeNumber
            && (!(a.chapterNumber == nil && a.volumeNumber == nil) || a.title == b.title)
    }

    private func isValidScanlatorMatch(for next: AidokuRunner.Chapter, current: Set<String>) -> Bool {
        let nextScanlators = Set(next.scanlators ?? [])
        return current.isEmpty ? nextScanlators.isEmpty : !current.isDisjoint(with: nextScanlators)
    }

    private func findBestChapterMatch(from index: Int, step: Int) -> AidokuRunner.Chapter {
        let firstCandidate = chapterList[index]
        let currentScanlators = Set(chapter.scanlators ?? [])

        var i = index
        while i >= 0 && i < chapterList.count {
            let next = chapterList[i]
            guard areDuplicates(next, firstCandidate) else { break }

            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: next.key)
            let isReadable = !next.locked || DownloadManager.shared.getDownloadStatus(for: identifier) == .finished

            if isReadable && isValidScanlatorMatch(for: next, current: currentScanlators) {
                return next
            }
            i += step
        }

        return firstCandidate
    }

    func getNextChapter() -> AidokuRunner.Chapter? {
        guard
            var index = chapterList.firstIndex(of: chapter)
        else {
            return nil
        }

        let skipDuplicates = UserDefaults.standard.bool(forKey: "Reader.skipDuplicateChapters")
        let markDuplicates = UserDefaults.standard.bool(forKey: "Reader.markDuplicateChapters")

        index -= 1
        var nextChapterInList: AidokuRunner.Chapter?

        while index >= 0 {
            let new = chapterList[index]
            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: new.key)

            let readable = !new.locked
                || DownloadManager.shared.getDownloadStatus(for: identifier) == .finished

            if readable {
                let isDuplicate = areDuplicates(new, chapter)

                if nextChapterInList == nil {
                    nextChapterInList = new
                }
                if markDuplicates && isDuplicate {
                    chaptersToMark.append(new)
                }
                if !isDuplicate {
                    return skipDuplicates ? findBestChapterMatch(from: index, step: -1) : nextChapterInList
                } else if !skipDuplicates && !markDuplicates {
                    return new
                }
            }
            index -= 1
        }
        return nil
    }

    func getPreviousChapter() -> AidokuRunner.Chapter? {
        guard
            var index = chapterList.firstIndex(of: chapter)
        else {
            return nil
        }
        // find previous non-duplicate chapter
        let markDuplicates = UserDefaults.standard.bool(forKey: "Reader.markDuplicateChapters")

        index += 1
        while index < chapterList.count {
            let new = chapterList[index]
            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: new.key)

            let readable = !new.locked
                || DownloadManager.shared.getDownloadStatus(for: identifier) == .finished

            if readable {
                let isDuplicate = areDuplicates(new, chapter)
                if !isDuplicate {
                    return findBestChapterMatch(from: index, step: 1)
                }
                if markDuplicates {
                    chaptersToMark.append(new)
                }
            }
            index += 1
        }
        return nil
    }

    func setChapter(_ chapter: AidokuRunner.Chapter) {
        guard chapter != self.chapter else { return }
        let leftEnteredFromBelow = enteredFromBelow

        // to the next chapter from the last page: the chapter left is completed (SUWA-17), right after its page
        // is saved below (two saves of the same history row at once: one of them failed). The list is the
        // source's, newest first. Only in the webtoon and paged readers: the text readers keep the SUWA-12 rule
        // (the scrolling one tells «previous chapter» and «this chapter» again when it puts the previous one in
        // above). And only the chapter being read, if its own last page was seen: never another one (C1)
        let isTextReader = reader is ReaderTextViewController || reader is ReaderPagedTextViewController
        var leftCompleted: (chapters: [AidokuRunner.Chapter], reason: String)?
        if
            !isTextReader,
            !leftEnteredFromBelow,
            !completionAttempted.contains(self.chapter.key),
            let oldIndex = chapterList.firstIndex(of: self.chapter),
            let newIndex = chapterList.firstIndex(of: chapter),
            let totalPages = toolbarView.totalPages, totalPages > 0,
            ReaderCompletion.chapterChangeCompletes(
                forward: newIndex < oldIndex,
                lastPageSeen: lastPageSeenChapters.contains(self.chapter.key),
                inForeground: appActivity.isActive
            ),
            !AppSettings.general.incognitoMode.get()
        {
            completionAttempted.insert(self.chapter.key)
            let readerType = String(describing: type(of: reader as Any))
            leftCompleted = (
                chaptersToMark,
                "lector: al capítulo siguiente desde la última página (\(readerType), página \(currentPage) de \(totalPages))"
            )
            if AppSettings.downloads.deleteDownloadAfterReading.get() {
                chaptersToRemoveDownload.append(self.chapter)
            }
        }

        // the old chapter is saved right away below, unless it is at the page it opened at or was saved at (another
        // device may have saved a newer one); nothing delayed may write it later, and from now on the saver knows this
        // page as saved (a chapter change by scrolling has no chapterOpened: what it knew was the old opening page)
        // a chapter entered from below and never gone up into: nothing of it is saved (the page is the other
        // chapter's)
        let needsSave = !leftEnteredFromBelow && readPositionSaver.claimImmediateSave(
            pageKey: ReadPosition.pageKey(chapter: self.chapter, page: currentPage, position: currentPosition),
            trackerKey: ReadPosition.pageKey(chapter: self.chapter, page: currentPage, position: nil)
        )
        if leftEnteredFromBelow {
            readPositionSaver.cancel()
        }

        // store current history data since it will change when new chapter loads
        let currentPage = currentPage
        let totalPages = toolbarView.totalPages
        let oldChapter = self.chapter
        Task { [manga, leftCompleted] in
            if needsSave {
                await updateReadPosition(currentPage: currentPage, totalPages: totalPages, chapter: oldChapter)
            } else if !leftEnteredFromBelow, !AppSettings.general.incognitoMode.get() {
                await saveReadingSession(chapter: oldChapter)
            }
            if let leftCompleted {
                await HistoryManager.shared.addHistory(mangaId: manga.identifier, chapters: leftCompleted.chapters, reason: leftCompleted.reason)
            }
            sessionReadPages = [self.currentPage]
            sessionStartDate = Date.now
            sessionLastInteraction = nil
        }

        // back to an earlier chapter (the list is the source's, newest first) by scrolling: entered from below
        let fromIndex = chapterList.firstIndex(of: oldChapter)
        let toIndex = chapterList.firstIndex(of: chapter)
        enteredFromBelow = if let fromIndex, let toIndex { toIndex > fromIndex } else { false }
        self.chapter = chapter
        self.chaptersToMark = [chapter]
        configureBarToggleTapGestures()
        configureDictionaryLookupGesture()
        configureDictionaryOverlayInteractionMode()
        loadNavbarTitle()
    }

    func setCurrentPage(_ page: Int, position: Double? = nil) {
        setCurrentPages(page...page, position: position)
    }

    func setCurrentPages(_ pages: ClosedRange<Int>) {
        setCurrentPages(pages, position: nil)
    }

    private func setCurrentPages(_ pages: ClosedRange<Int>, position: Double? = nil) {
        // nothing from a reader while the app isn't in front: not the page, not a save, not «seen» (SUWA-12 I1)
        guard appActivity.isActive else { return }
        guard let totalPages = toolbarView.totalPages else { return }
        // a chapter entered from below: the user went up into it (a text reader only reports once in its text)
        let reportsFromText = reader is ReaderTextViewController || reader is ReaderPagedTextViewController
        if enteredFromBelow, reportsFromText || pages.upperBound < totalPages {
            enteredFromBelow = false
        }
        // still at its end (its last page, the transition after it): shown, but not read going down: not seen, not
        // saved, not completed (SUWA-17 D5)
        if enteredFromBelow {
            toolbarView.currentPage = max(1, min(pages.lowerBound, totalPages))
            toolbarView.updateSliderPosition()
            return
        }
        let previousPage = currentPage

        updateDescriptionButton(pages: pages)
        updateAutoScrollButton()

        sessionLastInteraction = Date.now
        for page in pages {
            guard page >= 1 && page <= totalPages else { continue }
            sessionReadPages.insert(page)
        }
        if pages.upperBound >= totalPages {
            lastPageSeenChapters.insert(chapter.key)
        }

        let page = max(1, min(pages.lowerBound, totalPages))
        currentPage = page
        currentPosition = position
        readPositionSaver.pageChanged(.init(chapter: chapter, page: page, totalPages: totalPages, scrollPosition: position))
        toolbarView.currentPage = page
        toolbarView.updateSliderPosition()
        // Mark as completed when reaching the last page
        // Exception: Don't mark for the pre-pagination placeholder (single text page before
        // ReaderPagedTextViewController has paginated it). Once paginated, even single-page
        // chapters should be marked as read.
        let isPrePaginationPlaceholder = totalPages == 1
            && self.pages.first?.isTextPage == true
            && !(reader is ReaderPagedTextViewController && (reader as? ReaderPagedTextViewController)?.hasPaginated == true)
        // the last page seen (now or before in this session), with the app in the foreground (SUWA-12 H1)
        let isTextReader = reader is ReaderTextViewController || reader is ReaderPagedTextViewController
        let completes = isTextReader
            ? ReaderCompletion.textPageReportCompletes(
                pages: pages, totalPages: totalPages, seenPages: sessionReadPages, previousPage: previousPage, inForeground: appActivity.isActive
            )
            : ReaderCompletion.pageReportCompletes(
                pages: pages, totalPages: totalPages, seenPages: sessionReadPages, previousPage: previousPage, inForeground: appActivity.isActive
            )
        if completes && !isPrePaginationPlaceholder {
            completionTrigger = "lector: página \(pages.lowerBound)...\(pages.upperBound) de \(totalPages)"
            setCompleted()
        }
    }

    private func updateDescriptionButton(pages: ClosedRange<Int>) {
        let pageItems = pages.compactMap { self.pages[safe: $0 - 1]?.toNew() }
        if pageItems.contains(where: { $0.hasDescription }) {
            descriptionButtonController.rootView = ReaderPageDescriptionButtonView(
                source: source,
                pages: pageItems
            )
            descriptionButtonController.view.isHidden = false
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.descriptionButtonController.view.alpha = 1
            }
        } else {
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.descriptionButtonController.view.alpha = 0
            } completion: { _ in
                self.descriptionButtonController.view.isHidden = true
            }
        }
    }

    func setPages(_ pages: [Page]) {
        // If already in a text reader with text pages, just update toolbar - don't trigger any switches
        if
            reader is ReaderPagedTextViewController || reader is ReaderTextViewController,
            pages.allSatisfy({ $0.isTextPage }),
            pages.count > 1
        {
            self.pages = pages
            toolbarView.totalPages = pages.count
            activityIndicator.stopAnimating()
            return
        }
        self.pages = pages
        toolbarView.totalPages = pages.count
        activityIndicator.stopAnimating()
        if pages.isEmpty {
            // no pages, show error
            showLoadFailAlert()
        } else if pages.count == 1 && pages[0].isTextPage {
            // single text page, should switch to text reader
            if !(reader is ReaderPagedTextViewController) && !(reader is ReaderTextViewController) {
                setReader(.text)
                setChapter(chapter)
                loadCurrentChapter()
            } else {
            }
        } else if reader is ReaderPagedTextViewController && pages.allSatisfy({ $0.isTextPage }) {
            // Already in paginated text reader with multiple text pages (from pagination)
            // Don't switch away - this is our internal page count update
            // Just update the toolbar, don't reload
        } else {
            // otherwise, make sure we're not in the text reader
            if reader is ReaderTextViewController || reader is ReaderPagedTextViewController {
                switch readingMode {
                    case .ltr, .rtl, .vertical:
                        setReader(.paged)
                    case .webtoon, .continuous:
                        setReader(.scroll)
                }
                setChapter(chapter)
                loadCurrentChapter()
            }
        }
    }

    func displayPage(_ page: Int) {
        toolbarView.displayPage(page)
    }

    func setSliderOffset(_ offset: CGFloat) {
        toolbarView.sliderView.currentValue = offset
    }

    @discardableResult
    func setCompleted() -> Bool {
        guard appActivity.isActive else { return false } // every reader, also the text one (SUWA-12 I1)
        guard !AppSettings.general.incognitoMode.get() else { return false }
        // once per chapter in this reader (it counted already)
        guard completionAttempted.insert(chapter.key).inserted else { return true }

        let reason = "\(completionTrigger) (\(String(describing: type(of: reader as Any))), página \(currentPage) de \(toolbarView.totalPages ?? 0))"
        completionTrigger = "lector"
        Task { [chaptersToMark] in
            await HistoryManager.shared.addHistory(
                mangaId: manga.identifier,
                chapters: chaptersToMark,
                reason: reason
            )
        }

        if AppSettings.downloads.deleteDownloadAfterReading.get() {
            chaptersToRemoveDownload.append(chapter)
        }
        return true
    }

    private func configureBarToggleTapGestures() {
        if let barToggleTapGesture {
            view.removeGestureRecognizer(barToggleTapGesture)
        }
        if let barToggleSecondaryTapGesture {
            view.removeGestureRecognizer(barToggleSecondaryTapGesture)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.delegate = self
        let singleTapLookupEnabled = isDictionarySingleTapLookupActiveForCurrentChapter
        configureNavigationBarDismissTapGesture(enabled: singleTapLookupEnabled)

        if !singleTapLookupEnabled, !UserDefaults.standard.bool(forKey: "Reader.disableDoubleTap") {
            let doubleTap = UITapGestureRecognizer(
                target: self,
                action: nil
            )
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
            barToggleSecondaryTapGesture = doubleTap
        } else {
            barToggleSecondaryTapGesture = nil
        }

        view.addGestureRecognizer(tap)
        barToggleTapGesture = tap
    }

    private func configureNavigationBarDismissTapGesture(enabled: Bool) {
        guard let navigationBar = navigationController?.navigationBar else { return }

        if barDismissNavigationBarTapGesture == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleNavigationBarTapToDismissBars(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            navigationBar.addGestureRecognizer(tap)
            barDismissNavigationBarTapGesture = tap
        }
        barDismissNavigationBarTapGesture?.isEnabled = enabled
    }

    @objc private func handleNavigationBarTapToDismissBars(_ gestureRecognizer: UITapGestureRecognizer) {
        guard gestureRecognizer.state == .ended else { return }
        guard isDictionarySingleTapLookupActiveForCurrentChapter else { return }
        hideBars()
    }

    private func configureDictionaryLookupGesture() {
        if let gesture = dictionaryLongPressGesture {
            view.removeGestureRecognizer(gesture)
            dictionaryLongPressGesture = nil
        }
        clearDictionarySelectionHighlight()
        dictionaryLongPressSelection = nil

        guard
            isDictionaryLongPressLookupActiveForCurrentChapter,
            !AppSettings.dictionary.textOverlayMode.get()
        else {
            return
        }

        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDictionaryLongPress(_:)))
        gesture.minimumPressDuration = 0.25
        gesture.allowableMovement = 60
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        dictionaryLongPressGesture = gesture
    }

    @objc private func handleDictionaryLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        guard
            isDictionaryLongPressLookupActiveForCurrentChapter,
            !AppSettings.dictionary.textOverlayMode.get(),
            !dictionaryCoordinator.isPopupVisible,
            LookupEngine.shared.isReady
        else {
            return
        }

        let point = gestureRecognizer.location(in: view)
        switch gestureRecognizer.state {
            case .began, .changed:
                guard
                    let reader = reader as? ReaderDictionaryReader,
                    let result = reader.recognizedText(at: point)
                else {
                    dictionaryLongPressSelection = nil
                    clearDictionarySelectionHighlight()
                    return
                }
                dictionaryLongPressSelection = result
                updateDictionarySelectionHighlight(text: result.text, charRects: result.charRects)

            case .ended:
                defer {
                    dictionaryLongPressSelection = nil
                    clearDictionarySelectionHighlight()
                }
                var selection = dictionaryLongPressSelection
                if selection == nil, let reader = reader as? ReaderDictionaryReader {
                    selection = reader.recognizedText(at: point)
                }
                if let selection {
                    _ = dictionaryCoordinator.performLookup(
                        text: selection.text,
                        contextText: selection.fullText,
                        anchorRect: selection.charRect,
                        charRects: selection.charRects,
                        page: currentPage
                    )
                }

            default:
                dictionaryLongPressSelection = nil
                clearDictionarySelectionHighlight()
        }
    }

    private func updateDictionarySelectionHighlight(text: String, charRects: [CGRect]) {
        dictionaryCoordinator.updateSelectionHighlight(text: text, charRects: charRects)
    }

    private func clearDictionarySelectionHighlight() {
        dictionaryCoordinator.clearSelectionHighlight()
    }
}

// MARK: - Tap Zones
extension ReaderViewController {
    private enum ReaderControlTapZoneConstants {
        static let minimumTapZoneHeight: CGFloat = 44
    }

    func updateTapZone() {
        let enabledTapZone = UserDefaults.standard.string(forKey: "Reader.tapZones")
        let tapZone: TapZone? = switch enabledTapZone {
            case "auto": switch reader {
                case is ReaderPagedViewController: .leftRight
                case is ReaderWebtoonViewController: .lShaped
                case is ReaderTextViewController: .lShaped
                case is ReaderPagedTextViewController: .leftRight  // Kindle-style tap zones
                default: .leftRight
            }
            case "left-right": .leftRight
            case "l-shaped": .lShaped
            case "kindle": .kindle
            case "edge": .edge
            default: nil
        }
        self.tapZone = tapZone
    }

    @objc func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        let point = gestureRecognizer.location(in: view)
        let overlayModeEnabled = AppSettings.dictionary.textOverlayMode.get()
        let singleTapLookupEnabled = isDictionarySingleTapLookupActiveForCurrentChapter
        let singleTapOCRLookupEnabled = singleTapLookupEnabled && !overlayModeEnabled

        // dismiss dictionary popup if visible
        if dictionaryCoordinator.isPopupVisible {
            dictionaryCoordinator.dismissAllPopups()
            return
        }

        // dismiss text overlay box if visible
        if
            overlayModeEnabled,
            let reader = reader as? ReaderDictionaryReader,
            reader.dismissActiveDictionaryOverlay()
        {
            return
        }

        // toggle bars when tapping safe areas
        if singleTapLookupEnabled, isReaderControlToggleTapZone(point) {
            toggleBarVisibility()
            return
        }

        // check for dictionary lookup
        if
            singleTapOCRLookupEnabled,
            let reader = reader as? ReaderDictionaryReader,
            LookupEngine.shared.isReady
        {
            if let result = reader.recognizedText(at: point) {
                if dictionaryCoordinator.performLookup(
                    text: result.text,
                    contextText: result.fullText,
                    anchorRect: result.charRect,
                    charRects: result.charRects,
                    page: currentPage
                ).openedPopup {
                    return
                }
            }
        }

        guard let reader, let tapZone else {
            toggleBarVisibility()
            return
        }

        let relativePoint = CGPoint(
            x: point.x / view.bounds.width,
            y: point.y / view.bounds.height
        )

        let type = tapZone.regions
            .first { $0.bounds.contains(relativePoint) }
            .map(\.type)

        if let type {
            // hide the bars when tapping regardless
            if let navigationController, navigationController.navigationBar.alpha > 0 {
                hideBars()
            }
            // handle page moving
            if UserDefaults.standard.bool(forKey: "Reader.invertTapZones") {
                switch type {
                    case .left: reader.moveRight()
                    case .right: reader.moveLeft()
                }
            } else {
                switch type {
                    case .left: reader.moveLeft()
                    case .right: reader.moveRight()
                }
            }
        } else {
            toggleBarVisibility()
        }
    }

    private func isReaderControlToggleTapZone(_ point: CGPoint) -> Bool {
        let topZoneHeight = readerControlTopTapZoneHeight
        if point.y <= topZoneHeight {
            return true
        }
        let bottomZoneMinY = view.bounds.height - readerControlBottomTapZoneHeight
        return point.y >= bottomZoneMinY
    }

    private var readerControlTopTapZoneHeight: CGFloat {
        view.safeAreaInsets.top + ReaderControlTapZoneConstants.minimumTapZoneHeight
    }

    private var readerControlBottomTapZoneHeight: CGFloat {
        view.safeAreaInsets.bottom + ReaderControlTapZoneConstants.minimumTapZoneHeight
    }
}

// MARK: - Apple Pencil Squeeze
extension ReaderViewController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        // if pencil squeezing is disabled globally, ignore interaction (hig)
        guard UIPencilInteraction.preferredSqueezeAction != .ignore else { return }

        switch squeeze.phase {
            case .began:
                squeezeStartTime = Date()
                longSqueezeTimer = Timer.scheduledTimer(
                    withTimeInterval: longSqueezeThreshold,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.longSqueezeTimer = nil
                        self?.openChapterList()
                    }
                }
            case .ended:
                guard let startTime = squeezeStartTime else { return }
                let duration = Date().timeIntervalSince(startTime)
                squeezeStartTime = nil
                longSqueezeTimer?.invalidate()
                longSqueezeTimer = nil

                if duration >= longSqueezeThreshold {
                    // long squeeze: chapter selector
                    squeezeTimer?.invalidate()
                    squeezeTimer = nil
                    return
                } else {
                    if let timer = squeezeTimer {
                        // double squeeze: previous page
                        timer.invalidate()
                        squeezeTimer = nil
                        previousPage()
                    } else {
                        // single squeeze: next page
                        squeezeTimer = Timer.scheduledTimer(
                            withTimeInterval: doubleSqueezeInterval,
                            repeats: false
                        ) { [weak self] _ in
                            Task { @MainActor in
                                self?.squeezeTimer = nil
                                self?.nextPage()
                            }
                        }
                    }
                }
            default:
                break
        }

    }

    private func nextPage() {
        switch readingMode {
            case .rtl: reader?.moveLeft()
            default: reader?.moveRight()
        }
    }

    private func previousPage() {
        switch readingMode {
            case .rtl: reader?.moveRight()
            default: reader?.moveLeft()
        }
    }
}

extension ReaderViewController {
    private func configureDictionaryOverlayInteractionMode() {
        guard let reader = reader as? ReaderDictionaryReader else { return }

        let mode: DictionaryOverlayInteractionMode
        if !AppSettings.dictionary.textOverlayMode.get() {
            mode = .none
        } else if isDictionarySingleTapLookupActiveForCurrentChapter {
            mode = .singleTap
        } else if isDictionaryLongPressLookupActiveForCurrentChapter {
            mode = .longPress
        } else {
            mode = .none
        }

        reader.setDictionaryOverlayInteractionMode(mode)
    }

    private func configureDictionaryOverlayTapHandler() {
        guard let reader = reader as? ReaderDictionaryReader else { return }
        reader.setDictionaryOverlayTapHandler { [weak self] text, contextText, rect, charRects in
            guard let self, AppSettings.dictionary.textOverlayMode.get() else { return }
            _ = dictionaryCoordinator.performLookup(
                text: text,
                contextText: contextText,
                anchorRect: rect,
                charRects: charRects,
                page: currentPage
            )
        }
    }
}

// MARK: - Bar Visibility
extension ReaderViewController {
    @objc func toggleBarVisibility() {
        guard let navigationController else { return }
        if !navigationController.navigationBar.isHidden {
            hideBars()
        } else {
            showBars()
        }
    }

    func showBars() {
        guard let navigationController else { return }

        navigationController.navigationBar.isHidden = true
        navigationController.isNavigationBarHidden = false

        UIView.animate(withDuration: CATransaction.animationDuration()) {
            self.statusBarHidden = false
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        } completion: { _ in
            NotificationCenter.default.post(name: .readerShowingBars, object: nil)

            UIView.setAnimationsEnabled(false)
            if navigationController.isToolbarHidden {
                (navigationController.value(forKey: "_floatingBarContainerView") as? UIView)?.alpha = 0
                navigationController.isToolbarHidden = false
            }
            navigationController.navigationBar.isHidden = false
            UIView.setAnimationsEnabled(true)
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                navigationController.navigationBar.alpha = 1
                navigationController.toolbar.alpha = 1
                (navigationController.value(forKey: "_floatingBarContainerView") as? UIView)?.alpha = 1
                self.node.backgroundColor = if AppSettings.appearance.useSystemAppearance.get() {
                    .systemBackground
                } else {
                    if AppSettings.appearance.appearance.get() == 0 {
                        .white
                    } else {
                        .black
                    }
                }
                self.node.layoutIfNeeded()
            }
        }
    }

    func hideBars() {
        guard let navigationController else { return }

        UIView.animate(withDuration: CATransaction.animationDuration()) {
            self.statusBarHidden = true
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        } completion: { _ in
            NotificationCenter.default.post(name: .readerHidingBars, object: nil)

            UIView.animate(withDuration: CATransaction.animationDuration()) {
                navigationController.navigationBar.alpha = 0
                navigationController.toolbar.alpha = 0

                (navigationController.value(forKey: "_floatingBarContainerView") as? UIView)?.alpha = 0

                self.node.backgroundColor = switch UserDefaults.standard.string(forKey: "Reader.backgroundColor") {
                    case "system":
                        .systemBackground
                    case "white":
                        .white
                    default:
                        .black
                }
                self.node.layoutIfNeeded()
            } completion: { _ in
                navigationController.isNavigationBarHidden = true
                navigationController.isToolbarHidden = true
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate
extension ReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return velocity.y > velocity.x && (abs(velocity.x) < 40 || abs(velocity.y) > abs(velocity.x) * 3)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard
            gestureRecognizer === barDismissNavigationBarTapGesture
                || gestureRecognizer === barToggleTapGesture
                || gestureRecognizer === barToggleSecondaryTapGesture
        else {
            return true
        }

        var view: UIView? = touch.view
        while let currentView = view {
            if currentView is UIControl {
                return false
            }
            view = currentView.superview
        }
        return true
    }
}

// MARK: - Keyboard Shortcuts
extension ReaderViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(
                title: NSLocalizedString("TURN_PAGE_LEFT"),
                action: #selector(moveLeft),
                input: UIKeyCommand.inputLeftArrow
            ),
            UIKeyCommand(
                title: NSLocalizedString("TURN_PAGE_RIGHT"),
                action: #selector(moveRight),
                input: UIKeyCommand.inputRightArrow
            ),
            UIKeyCommand(
                title: NSLocalizedString("TOGGLE_PAGE_OFFSET"),
                action: #selector(toggleOffset),
                input: "o"
            ),
            UIKeyCommand(
                title: NSLocalizedString("CHAPTER_FORWARD"),
                action: #selector(nextChapter),
                input: ","
            ),
            UIKeyCommand(
                title: NSLocalizedString("CHAPTER_BACKWARD"),
                action: #selector(previousChapter),
                input: "."
            ),
            UIKeyCommand(
                title: NSLocalizedString("OPEN_CHAPTER_LIST"),
                action: #selector(openChapterList),
                input: "\t"
            ),
            UIKeyCommand(
                title: NSLocalizedString("TOGGLE_BARS"),
                action: #selector(toggleBarVisibility),
                input: " "
            ),
            UIKeyCommand(
                title: NSLocalizedString("CLOSE_READER"),
                action: #selector(close),
                input: UIKeyCommand.inputEscape
            )
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc func moveLeft() {
        reader?.moveLeft()
    }

    @objc func moveRight() {
        reader?.moveRight()
    }

    @objc func toggleOffset() {
        reader?.toggleOffset()
    }

    // as the chapter list: the chapter opens where it was left, and that page is not a change (SUWA-17 D1)
    @objc func nextChapter() {
        if let nextChapter = getNextChapter() {
            setChapter(nextChapter)
            loadCurrentChapter()
        }
    }

    @objc func previousChapter() {
        if let previousChapter = getPreviousChapter() {
            setChapter(previousChapter)
            loadCurrentChapter()
        }
    }
}

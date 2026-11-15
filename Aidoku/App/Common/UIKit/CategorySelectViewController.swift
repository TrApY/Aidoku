//
//  CategorySelectViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 5/25/22.
//

import UIKit
import AidokuRunner

class CategorySelectViewController: UITableViewController {
    let manga: AidokuRunner.Manga

    var categories: [String] = []
    var selectedCategories: [String] = []

    init(manga: AidokuRunner.Manga) {
        self.manga = manga
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("CATEGORIES")

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(addCategory))

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UITableViewCell")

        Task {
            let repo = DataRepositories.shared.categories
            let loadedCategories = await repo.titles(includeFilterGroups: false)
            // [] if the manga is not in the library
            let loadedSelected = await repo.categories(of: manga.identifier)
            (categories, selectedCategories) = (loadedCategories, loadedSelected)
            tableView.reloadData()
        }
    }

    @objc func close() {
        dismiss(animated: true)
    }

    @objc func addCategory() {
        close()
        Task {
            let inLibrary = await DataRepositories.shared.library.contains(manga.identifier)
            if !inLibrary {
                await MangaManager.shared.addToLibrary(
                    manga: manga,
                    chapters: manga.chapters ?? [],
                    fetchMangaDetails: true
                )
            }
            await MangaManager.shared.setCategories(
                mangaId: manga.identifier,
                categories: selectedCategories
            )
        }
    }
}

// MARK: - Table View Data Source
extension CategorySelectViewController {

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        categories.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UITableViewCell", for: indexPath)

        cell.textLabel?.text = categories[indexPath.row]
        if selectedCategories.contains(categories[indexPath.row]) {
            cell.accessoryType = .checkmark
        } else {
            cell.accessoryType = .none
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath) {
            if cell.accessoryType == .checkmark {
                cell.accessoryType = .none
                selectedCategories.removeAll(where: { $0 == categories[indexPath.row] })
            } else {
                cell.accessoryType = .checkmark
                selectedCategories.append(categories[indexPath.row])
            }
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

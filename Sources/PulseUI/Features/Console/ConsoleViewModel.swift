// The MIT License (MIT)
//
// Copyright (c) 2020–2022 Alexander Grebenyuk (github.com/kean).

import CoreData
import PulseCore
import Combine
import SwiftUI

@available(iOS 13.0, tvOS 14.0, watchOS 7.0, *)
final class ConsoleViewModel: NSObject, NSFetchedResultsControllerDelegate, ObservableObject {
    let configuration: ConsoleConfiguration

#if os(iOS)
    let table: ConsoleTableViewModel

    @Published private(set) var messages: [LoggerMessageEntity] = [] {
        didSet { table.entities = messages }
    }
#else
    @Published private(set) var messages: [LoggerMessageEntity] = []
#endif

    var entities: [LoggerMessageEntity] { messages }

    // Search criteria
    let searchCriteria: ConsoleSearchCriteriaViewModel
    @Published var isOnlyErrors: Bool = false
    @Published var filterTerm: String = ""

#if os(watchOS)
    @Published private(set) var quickFilters: [QuickFilterViewModel] = []
#endif

    // Apple Watch file transfers
#if os(watchOS) || os(iOS)
    @Published private(set) var fileTransferStatus: FileTransferStatus = .initial
    @Published var fileTransferError: FileTransferError?
#endif

    var onDismiss: (() -> Void)?

    private(set) var store: LoggerStore
    private let controller: NSFetchedResultsController<LoggerMessageEntity>
    private var latestSessionId: String?
    private var cancellables: [AnyCancellable] = []

    init(store: LoggerStore, configuration: ConsoleConfiguration = .default) {
        self.store = store
        self.configuration = configuration

        let request = NSFetchRequest<LoggerMessageEntity>(entityName: "\(LoggerMessageEntity.self)")
        request.fetchBatchSize = 250
        request.relationshipKeyPathsForPrefetching = ["request"]
        request.sortDescriptors = [NSSortDescriptor(keyPath: \LoggerMessageEntity.createdAt, ascending: false)]

        self.controller = NSFetchedResultsController<LoggerMessageEntity>(fetchRequest: request, managedObjectContext: store.container.viewContext, sectionNameKeyPath: nil, cacheName: nil)

        self.searchCriteria = ConsoleSearchCriteriaViewModel(isDefaultStore: store === LoggerStore.default)
#if os(iOS)
        self.table = ConsoleTableViewModel(store: store, searchCriteriaViewModel: searchCriteria)
#endif

        super.init()

        controller.delegate = self

        $filterTerm.throttle(for: 0.25, scheduler: RunLoop.main, latest: true).dropFirst().sink { [weak self] filterTerm in
            self?.refresh(filterTerm: filterTerm)
        }.store(in: &cancellables)

        searchCriteria.dataNeedsReload.throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true).sink { [weak self] in
            self?.refreshNow()
        }.store(in: &cancellables)

        $isOnlyErrors.receive(on: DispatchQueue.main).dropFirst().sink { [weak self] _ in
            self?.refreshNow()
        }.store(in: &cancellables)

        refreshNow()

#if os(watchOS) || os(iOS)
        LoggerSyncSession.shared.$fileTransferStatus.sink(receiveValue: { [weak self] in
            self?.fileTransferStatus = $0
            if case let .failure(error) = $0 {
                self?.fileTransferError = FileTransferError(message: error.localizedDescription)
            }
        }).store(in: &cancellables)
#endif

#if os(iOS)
        store.backgroundContext.perform {
            self.getAllLabels()
        }
#endif
    }

    // MARK: Refresh

    private func refreshNow() {
        refresh(filterTerm: filterTerm)
    }

    private func refresh(filterTerm: String) {
        // Reset quick filters
        refreshQuickFilters(criteria: searchCriteria.criteria)

        // Get sessionId
        if latestSessionId == nil {
            latestSessionId = messages.first?.session
        }
        let sessionId = store === LoggerStore.default ? LoggerSession.current.id.uuidString : latestSessionId

        // Search messages
        ConsoleSearchCriteria.update(request: controller.fetchRequest, filterTerm: filterTerm, criteria: searchCriteria.criteria, filters: searchCriteria.filters, sessionId: sessionId, isOnlyErrors: isOnlyErrors)
        try? controller.performFetch()

        self.messages = controller.fetchedObjects ?? []
    }

    // MARK: Labels

    private func getAllLabels() {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "\(LoggerMessageEntity.self)")

        // Required! Unless you set the resultType to NSDictionaryResultType, distinct can't work.
        // All objects in the backing store are implicitly distinct, but two dictionaries can be duplicates.
        // Since you only want distinct names, only ask for the 'name' property.
        fetchRequest.resultType = .dictionaryResultType
        fetchRequest.propertiesToFetch = ["label"]
        fetchRequest.returnsDistinctResults = true

        // Now it should yield an NSArray of distinct values in dictionaries.
        let map = (try? store.backgroundContext.fetch(fetchRequest)) ?? []
        let values = (map as? [[String: String]])?.compactMap { $0["label"] }
        let set = Set(values ?? [])

        DispatchQueue.main.async {
            self.searchCriteria.setInitialLabels(set)
        }
    }

    // MARK: Pins

    private func refreshQuickFilters(criteria: ConsoleSearchCriteria) {
#if os(watchOS)
        quickFilters = searchCriteria.makeQuickFilters()
#endif
    }

    func share(as output: ShareStoreOutput) -> ShareItems {
#if os(iOS)
        return ShareItems(store: store, output: output)
#else
        return ShareItems(messages: store)
#endif
    }

    func buttonRemoveAllMessagesTapped() {
        store.removeAll()

#if os(iOS)
        runHapticFeedback(.success)
        ToastView {
            HStack {
                Image(systemName: "trash")
                Text("All messages removed")
            }
        }.show()
#endif
    }

#if os(watchOS) || os(iOS)
    @available(watchOS 7.0, *)
    func tranferStore() {
        LoggerSyncSession.shared.transfer(store: store)
    }
#endif

    // MARK: - NSFetchedResultsControllerDelegate

    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        switch type {
        case .insert:
            if let entity = anObject as? LoggerMessageEntity {
                searchCriteria.didInsertEntity(entity)
            }
        default:
            break
        }
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        self.messages = self.controller.fetchedObjects ?? []
    }
}

struct ConsoleMatch {
    let index: Int
    let objectID: NSManagedObjectID
}

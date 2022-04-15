//
//  PlanetDataController.swift
//  Planet
//
//  Created by Kai on 2/15/22.
//

import SwiftUI
import Foundation
import CoreData
import FeedKit
import ENSKit


enum PublicGateway: String {
    case cloudflare = "www.cloudflare-ipfs.com"
    case ipfs = "ipfs.io"
    case dweb = "dweb.link"
}

class PlanetDataController: NSObject {
    static let shared: PlanetDataController = .init()

    let titles = ["Hello and Welcome", "Hello World", "New Content Here!"]
    let contents = ["No content yet.", "This is a demo content.", "Hello from planet demo."]

    var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "Planet")

        container.loadPersistentStores { storeDescription, error in
            debugPrint("Store Description: \(storeDescription)")
            if let error = error {
                fatalError("Unable to load data store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }()

    // MARK: - -
    func saveContext() {
        let context = persistentContainer.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            debugPrint("Failed to save persistent container: \(error)")
        }
    }

    // MARK: Create Type 0 Planet: planet://ipns

    func createPlanet(withID id: UUID, name: String, about: String, keyName: String?, keyID: String?, ipns: String?) -> Planet? {
        let ctx = persistentContainer.viewContext
        let planet = Planet(context: ctx)
        planet.id = id
        planet.type = .planet
        planet.created = Date()
        planet.name = name.sanitized()
        planet.about = about
        planet.keyName = keyName
        planet.keyID = keyID
        planet.ipns = ipns
        do {
            try ctx.save()
            debugPrint("Type 0 Planet created: \(planet)")
            PlanetManager.shared.setupDirectory(forPlanet: planet)
            return planet
        } catch {
            debugPrint("Failed to create new Type 0 Planet: \(planet), error: \(error)")
            return nil
        }
    }

    // MARK: Create Type 1 Planet: planet://ens

    func createPlanetENS(ens: String) -> Planet? {
        let ctx = persistentContainer.viewContext
        let planet = Planet(context: ctx)
        planet.id = UUID()
        planet.type = .ens
        planet.created = Date()
        planet.name = ens
        planet.about = ""
        planet.ens = ens
        do {
            try ctx.save()
            debugPrint("Type 1 ENS planet created: \(ens)")
            PlanetManager.shared.setupDirectory(forPlanet: planet)
            return planet
        } catch {
            debugPrint("Failed to create new Type 1 Planet: \(ens), error: \(error)")
            return nil
        }
    }

    // MARK: Create Type 2 Planet: planet://ipns

    // MARK: Create Type 3 Planet: https://domain/feed.json

    func createPlanet(endpoint: String) -> Planet? {
        guard let url = URL(string: endpoint) else { return nil }
        if url.path.count == 1 { return nil }
        let ctx = persistentContainer.viewContext
        let planet = Planet(context: ctx)
        planet.id = UUID()
        planet.type = .dns
        planet.created = Date()
        planet.name = url.host
        planet.about = ""
        planet.dns = url.host
        planet.feedAddress = endpoint
        do {
            try ctx.save()
            debugPrint("Type 3 DNS planet created: \(url.host!)")
            return planet
        } catch {
            debugPrint("Failed to create new Type 3 DNS Planet: \(url.host!), error: \(error)")
            return nil
        }

    }

    // MARK: Check update for Type 1 ENS

    func checkUpdateForPlanetENS(planet: Planet) async {
        if let id = planet.id, let ens = planet.ens {
            do {
                let enskit = ENSKit(/* jsonrpcClient: InfuraEthereumAPI(url: URL("https://mainnet.infura.io/v3/<projectid>")! */)
                let result = try await enskit.resolve(name: ens)
                debugPrint("ENSKit.resolve(\(ens)) => \(result?.absoluteString ?? "nil")")
                if let contentHash = result,
                   contentHash.scheme?.lowercased() == "ipfs" {
                    let s = contentHash.absoluteString
                    let ipfs = String(s.suffix(from: s.index(s.startIndex, offsetBy: 7)))
                    updatePlanetENSContentHash(forID: id, contentHash: ipfs)
                    await checkContentUpdateForPlanetENS(forID: id, ipfs: ipfs)
                }
                let avatarResult = try await enskit.avatar(name: ens)
                debugPrint("ENSKit.avatar(\(ens)) => \(avatarResult?.description ?? "nil")")
                if let avatar = avatarResult {
                    if let image = NSImage(data: avatar) {
                        PlanetManager.shared.updateAvatar(forPlanet: planet, image: image)
                    }
                }
            } catch {
                debugPrint("Error loading ENS metadata: \(String(describing: error))")
            }
        }
    }

    func checkContentUpdateForPlanetENS(forID id: UUID, ipfs: String) async {
        let url = URL(string: "http://127.0.0.1:\(PlanetManager.shared.gatewayPort)/ipfs/\(ipfs)")!
        debugPrint("Trying to access IPFS content: \(url)")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    debugPrint("IPFS content returns 200 OK: \(url)")
                    // Try detect if there is a feed
                    // The better way would be to parse the HTML and check if it has a feed
                    let feedURL = URL(string: "http://127.0.0.1:\(PlanetManager.shared.gatewayPort)/ipfs/\(ipfs)/feed.xml")!
                    Task.init(priority: .background) {
                        await parseFeedForPlanet(forID: id, feedURL: feedURL)
                    }
                } else {
                    debugPrint("IPFS content returns \(httpResponse.statusCode): \(url)")
                }
            }
        }
        catch {
           debugPrint("Error loading IPFS content: \(url): \(String(describing: error))")
        }
    }

    func parseFeedForPlanet(forID id: UUID, feedURL: URL) async {
        let parser = FeedParser(URL: feedURL)
        parser.parseAsync(queue: DispatchQueue.global(qos: .userInitiated)) { (result) in
            // Do your thing, then back to the Main thread
            switch result {
                case .success(let feed):
                    switch feed {
                        case let .atom(feed):       // Atom Syndication Format Feed
                            var articles: [PlanetFeedArticle] = []
                            for entry in feed.entries! {
                                guard let entryURL = URL(string: entry.links![0].attributes!.href!) else { continue }
                                let entryLink = "\(entryURL.scheme!)://\(entryURL.host!)\(entryURL.path)"
                                guard let entryTitle = entry.title else { continue }
                                let entryContent = entry.content?.attributes?.src ?? ""
                                let entryPublished = entry.published ?? Date()
                                let a = PlanetFeedArticle(id: UUID(), created: entryPublished, title: entryTitle, content: entryContent, link: entryLink)
                                articles.append(a)
                            }
                            debugPrint("Atom Feed: Found \(articles.count) articles")
                            PlanetDataController.shared.batchCreateRSSArticles(articles: articles, planetID: id)
                        case let .rss(feed):        // Really Simple Syndication Feed
                            var articles: [PlanetFeedArticle] = []
                            for item in feed.items! {
                                guard let itemLink = URL(string: item.link!) else { continue }
                                guard let itemTitle = item.title else { continue }
                                let itemDescription = item.description ?? ""
                                let itemPubdate = item.pubDate ?? Date()
                                debugPrint("\(itemTitle) \(itemLink.path)")
                                let a = PlanetFeedArticle(id: UUID(), created: itemPubdate, title: itemTitle, content: itemDescription, link: itemLink.path)
                                articles.append(a)
                            }
                            debugPrint("RSS: Found \(articles.count) articles")
                            PlanetDataController.shared.batchCreateRSSArticles(articles: articles, planetID: id)
                        case let .json(feed):       // JSON Feed
                            let feedTitle = feed.title ?? ""
                            let feedDescription = feed.description ?? ""
                            PlanetDataController.shared.updatePlanet(withID: id, name: feedTitle, about: feedDescription)
                            // Fetch feed avatar if any
                            if let imageURL = feed.icon {
                                let url = URL(string: imageURL)!
                                let data = try! Data(contentsOf: url)
                                let image = NSImage(data: data)
                                PlanetDataController.shared.updatePlanetAvatar(forID: id, image: image)
                            }
                            var articles: [PlanetFeedArticle] = []
                            for item in feed.items! {
                                guard let itemLink = URL(string: item.url!) else { continue }
                                guard let itemTitle = item.title else { continue }
                                let itemContentHTML = item.contentHtml ?? ""
                                let itemDatePublished = item.datePublished ?? Date()
                                debugPrint("\(itemTitle) \(itemLink.path)")
                                let a = PlanetFeedArticle(id: UUID(), created: itemDatePublished, title: itemTitle, content: itemContentHTML, link: item.url!)
                                articles.append(a)
                            }
                            debugPrint("JSON Feed: Found \(articles.count) articles")
                            PlanetDataController.shared.batchCreateRSSArticles(articles: articles, planetID: id)
                    }
                case .failure(let error):
                    print(error)
                }
            DispatchQueue.main.async {
                // ..and update the UI
            }
        }
    }

    // MARK: Check update for Type 3 DNS

    func checkUpdateForPlanetDNS(planet: Planet) async {
        if let id = planet.id, let feedAddress = planet.feedAddress {
            let url = URL(string: feedAddress)!
            debugPrint("Trying to fetch Feed: \(feedAddress)")
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        await parseFeedForPlanet(forID: id, feedURL: url)
                    }
                }
            } catch {
                debugPrint("Error fetching feed: \(url): \(String(describing: error))")
            }
        }
    }

    func updatePlanetMetadata(forID id: UUID, name: String?, about: String?, ipns: String?) {
        let ctx = persistentContainer.viewContext
        guard let planet = getPlanet(id: id) else { return }
        if let name = name, name != "" {
            planet.name = name
        }
        if let about = about, about != "" {
            planet.about = about
        }
        if let ipns = ipns {
            planet.ipns = ipns
        }
        do {
            try ctx.save()
            debugPrint("planet updated: \(planet)")
        } catch {
            debugPrint("failed to update planet: \(planet), error: \(error)")
        }
    }

    func updatePlanetFeedSHA256(forID id: UUID, feedSHA256: String) {
        let ctx = persistentContainer.viewContext
        guard let planet = getPlanet(id: id) else { return }
        planet.feedSHA256 = feedSHA256
        do {
            try ctx.save()
            debugPrint("Planet feed SHA256 updated: \(feedSHA256)")
        } catch {
            debugPrint("Failed to update planet feed SHA256: \(planet), error: \(error)")
        }
    }

    func updatePlanetENSContentHash(forID id: UUID, contentHash: String) {
        let ctx = persistentContainer.viewContext
        guard let planet = getPlanet(id: id) else { return }
        planet.ipfs = contentHash
        do {
            try ctx.save()
            debugPrint("ENS planet IPFS content hash updated: \(planet.name) \(contentHash)")
        } catch {
            debugPrint("failed to update planet: \(planet.name), error: \(error)")
        }
    }

    func updatePlanet(withID id: UUID, name: String, about: String) {
        let ctx = persistentContainer.viewContext
        guard let planet = getPlanet(id: id) else { return }
        if name != "" {
            planet.name = name
        }
        if about != "" {
            planet.about = about
        }
        do {
            try ctx.save()
            Task.init(priority: .utility) {
                await PlanetManager.shared.publishForPlanet(planet: planet)
            }
        } catch {
            debugPrint("failed to update planet: \(planet), error: \(error)")
        }
    }

    func updatePlanetAvatar(forID id: UUID, image: NSImage?) {
        do {
            if image == nil { return }
            let planetPath = PlanetManager.shared.planetsPath().appendingPathComponent(id.uuidString)
            if !FileManager.default.fileExists(atPath: planetPath.path) {
                try FileManager.default.createDirectory(at: planetPath, withIntermediateDirectories: true, attributes: nil)
            }
            let avatarPath = planetPath.appendingPathComponent("avatar.png")

            if FileManager.default.fileExists(atPath: avatarPath.path) {
                try FileManager.default.removeItem(at: avatarPath)
            }
            image!.imageSave(avatarPath)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .updateAvatar, object: nil)
            }
        } catch {
            debugPrint("Planet Avatar failed to update: \(error)")
        }
    }

    func updateArticleReadStatus(article: PlanetArticle, read: Bool = true) {
        let ctx = persistentContainer.viewContext
        guard let a = getArticle(id: article.id!) else { return }
        a.isRead = read
        do {
            try ctx.save()
            debugPrint("Read: article read status updated: \(a.isRead)")
        } catch {
            debugPrint("Read: failed to update article read status: \(a), error: \(error)")
        }
    }

    func updateArticleStarStatus(article: PlanetArticle, starred: Bool = true) {
        let ctx = persistentContainer.viewContext
        guard let a = getArticle(id: article.id!) else { return }
        a.isStarred = starred
        do {
            try ctx.save()
            debugPrint("Starred: article star status updated: \(a.isStarred)")
        } catch {
            debugPrint("Starred: failed to update article star status: \(a), error: \(error)")
        }
    }

    func fixPlanet(_ planet: Planet) async {
        let articles = getArticles(byPlanetID: planet.id!)
        let ctx = persistentContainer.viewContext
        for article in articles {
            if let a = PlanetDataController.shared.getArticle(id: article.id!) {
                if planet.isMyPlanet() {
                    if a.link != "/\(a.id!.uuidString)/" {
                        a.link = "/\(a.id!.uuidString)/"
                    }
                }
            }
        }
        do {
            try ctx.save()
            debugPrint("Fix Planet Done: \(planet.id!) - \(planet.name ?? "Planet \(planet.id!.uuidString)")")
        } catch {
            debugPrint("Failed to batch fix planet articles: \(planet.name ?? "Planet \(planet.id!.uuidString)"), error: \(error)")
        }
    }

    func createArticle(withID id: UUID, forPlanet planetID: UUID, title: String, content: String, link: String) async {
        guard let planet = getPlanet(id: planetID) else { return }
        guard _articleExists(id: id) == false else { return }
        let ctx = persistentContainer.viewContext
        let article = PlanetArticle(context: ctx)
        if planet.isMyPlanet() {
            article.id = id
        } else {
            article.id = UUID()
        }
        article.planetID = planetID
        article.title = title
        article.content = content
        if planet.isMyPlanet() {
            article.link = "/\(id)/"
        } else {
            article.link = link
        }
        article.created = Date()
        if planet.isMyPlanet() {
            article.isRead = true
        }
        do {
            try ctx.save()
            debugPrint("planet article created: \(article)")
            if planet.isMyPlanet() == false { return }
            await PlanetManager.shared.renderArticleToDirectory(fromArticle: article)
            await PlanetManager.shared.publishForPlanet(planet: planet)
        } catch {
            debugPrint("failed to create new planet article: \(article), error: \(error)")
        }
    }

    func batchUpdateArticles(articles: [PlanetFeedArticle], planetID: UUID) async {
        let ctx = persistentContainer.viewContext
        for article in articles {
            let a = PlanetDataController.shared.getArticle(id: article.id)
            if a != nil {
                a!.title = article.title
                a!.link = article.link ?? "/\(a!.id)/"
            }
        }
        do {
            try ctx.save()
            debugPrint("planet articles updated: \(articles)")
            // MARK: TODO: cache following planets' articles.
        } catch {
            debugPrint("failed to batch update planet articles: \(articles), error: \(error)")
        }
    }

    func batchCreateArticles(articles: [PlanetFeedArticle], planetID: UUID) async {
        let ctx = persistentContainer.viewContext
        for article in articles {
            let a = PlanetArticle(context: ctx)
            a.id = UUID()
            a.planetID = planetID
            a.title = article.title
            a.link = article.link
            a.created = article.created
        }
        do {
            try ctx.save()
            debugPrint("planet articles created: \(articles)")
            // MARK: TODO: cache following planets' articles.
        } catch {
            debugPrint("failed to batch create new planet articles: \(articles), error: \(error)")
        }
    }

    func batchImportArticles(articles: [PlanetFeedArticle], planetID: UUID) async {
        let ctx = persistentContainer.viewContext
        for article in articles {
            let a = PlanetArticle(context: ctx)
            a.id = article.id
            a.planetID = planetID
            a.title = article.title
            a.link = article.link
            a.created = article.created
        }
        do {
            try ctx.save()
            debugPrint("planet articles created: \(articles)")
            // MARK: TODO: cache following planets' articles.
        } catch {
            debugPrint("failed to batch create new planet articles: \(articles), error: \(error)")
        }
    }

    func batchCreateRSSArticles(articles: [PlanetFeedArticle], planetID: UUID) {
        let ctx = persistentContainer.viewContext
        for article in articles {
            let a = PlanetDataController.shared.getArticle(link: article.link!, planetID: planetID)
            if a == nil {
                let newArticle = PlanetArticle(context: ctx)
                newArticle.id = UUID()
                newArticle.planetID = planetID
                newArticle.title = article.title
                newArticle.link = article.link
                newArticle.created = article.created
            }
        }
        do {
            try ctx.save()
            debugPrint("planet RSS articles created: \(articles)")
            // MARK: TODO: cache following planets' articles.
        } catch {
            debugPrint("failed to batch create new planet articles: \(articles), error: \(error)")
        }
    }

    func batchDeleteArticles(articles: [PlanetArticle]) async {
        let ctx = persistentContainer.viewContext
        for a in articles {
            ctx.delete(a)
        }
        do {
            try ctx.save()
        } catch {
            debugPrint("failed to delete articles: \(error)")
        }
    }

    func updateArticle(withID id: UUID, title: String, content: String) {
        let ctx = persistentContainer.viewContext
        guard let article = getArticle(id: id) else { return }
        article.title = title
        article.content = content
        if article.link == nil {
            article.link = "/\(id)/"
        }
        do {
            try ctx.save()
            refreshArticle(article)
        } catch {
            debugPrint("failed to update planet article: \(article), error: \(error)")
        }
    }

    func refreshArticle(_ article: PlanetArticle) {
        Task.init(priority: .utility) {
            guard let planet = getPlanet(id: article.planetID!) else { return }
            if planet.isMyPlanet() {
                await PlanetManager.shared.renderArticleToDirectory(fromArticle: article)
                if let id = article.id {
                    DispatchQueue.global(qos: .background).async {
                        DispatchQueue.main.async {
                            debugPrint("about to refresh article: \(article) ...")
                            NotificationCenter.default.post(name: .refreshArticle, object: id)
                        }
                    }
                }
                await PlanetManager.shared.publishForPlanet(planet: planet)
                do {
                    try await PlanetDataController.shared.pingPublicGatewayForArticle(article: article, gateway: .dweb)
                    try await PlanetDataController.shared.pingPublicGatewayForArticle(article: article, gateway: .cloudflare)
                    try await PlanetDataController.shared.pingPublicGatewayForArticle(article: article, gateway: .ipfs)
                } catch {
                    // handle the error here in some way
                }
            }
        }
    }

    func getArticlePublicLink(article: PlanetArticle, gateway: PublicGateway = .dweb) -> String {
        guard let planet = getPlanet(id: article.planetID!) else { return "" }
        switch (planet.type) {
        case .planet:
            return "https://\(gateway.rawValue)/ipns/\(planet.ipns!)\(article.link!)"
        case .ens:
            return "https://\(gateway.rawValue)/ipfs/\(planet.ipfs!)\(article.link!)"
        case .dns:
            return "\(article.link!)"
        default:
            return "https://\(gateway.rawValue)/ipns/\(planet.ipns!)\(article.link!)"
        }
    }

    func copyPublicLinkOfArticle(_ article: PlanetArticle) {
        let publicLink = getArticlePublicLink(article: article, gateway: .dweb)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(publicLink, forType: .string)
    }

    func openInBrowser(_ article: PlanetArticle) {
        let publicLink = getArticlePublicLink(article: article, gateway: .dweb)
        if let url = URL(string: publicLink) {
            NSWorkspace.shared.open(url)
        }
    }

    func pingPublicGatewayForArticle(article: PlanetArticle, gateway: PublicGateway = .dweb) async throws {
        let publicLink = getArticlePublicLink(article: article, gateway: gateway)
        guard let url = URL(string: publicLink) else {
            return
        }

        // Use the async variant of URLSession to fetch data
        // Code might suspend here
        let (_, _) = try await URLSession.shared.data(from: url)

        debugPrint("Pinged public gateway: \(publicLink)")
    }

    func removePlanet(_ planet: Planet) {
        guard planet.id != nil else { return }
        let uuid = planet.id!
        let context = persistentContainer.viewContext
        let articlesToDelete = getArticles(byPlanetID: uuid)
        for a in articlesToDelete {
            context.delete(a)
        }
        context.delete(planet)
        do {
            try context.save()
            PlanetManager.shared.destroyDirectory(fromPlanet: uuid)
            self.reportDatabaseStatus()
            DispatchQueue.main.async {
                PlanetStore.shared.selectedPlanet = UUID().uuidString
                PlanetStore.shared.selectedArticle = UUID().uuidString
            }
        } catch {
            debugPrint("failed to delete planet: \(planet), error: \(error)")
        }
    }

    func getPlanet(id: UUID) -> Planet? {
        let request: NSFetchRequest<Planet> = Planet.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let context = persistentContainer.viewContext
        do {
            return try context.fetch(request).first
        } catch {
            debugPrint("failed to get planet: \(error), target uuid: \(id)")
        }
        return nil
    }

    func getArticle(id: UUID) -> PlanetArticle? {
        let request: NSFetchRequest<PlanetArticle> = PlanetArticle.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let context = persistentContainer.viewContext
        do {
            return try context.fetch(request).first
        } catch {
            debugPrint("failed to get article: \(error), target uuid: \(id)")
        }
        return nil
    }

    func getArticle(link: String, planetID: UUID) -> PlanetArticle? {
        let request: NSFetchRequest<PlanetArticle> = PlanetArticle.fetchRequest()
        let predicate1: NSPredicate = NSPredicate(format: "link == %@", link as CVarArg)
        let predicate2: NSPredicate = NSPredicate(format: "planetID == %@", planetID as CVarArg)
        let predicateCompound = NSCompoundPredicate.init(type: .and, subpredicates: [predicate1, predicate2])
        request.predicate = predicateCompound
        let context = persistentContainer.viewContext
        do {
            return try context.fetch(request).first
        } catch {
            debugPrint("failed to get article: \(error), link: \(link), planetID: \(planetID)")
        }
        return nil
    }

    func getArticles(byPlanetID id: UUID) -> [PlanetArticle] {
        let request: NSFetchRequest<PlanetArticle> = PlanetArticle.fetchRequest()
        request.predicate = NSPredicate(format: "planetID == %@", id as CVarArg)
        let context = persistentContainer.viewContext
        do {
            return try context.fetch(request)
        } catch {
            debugPrint("failed to get article: \(error), target uuid: \(id)")
        }
        return []
    }

    func getArticleStatus(byPlanetID id: UUID) -> (unread: Int, total: Int) {
        var unread: Int = 0
        var total: Int = 0
        let articles = getArticles(byPlanetID: id)
        total = articles.count
        unread = articles.filter({ a in
            return !a.isRead
        }).count
        return (unread, total)
    }

    func getLocalIPNSs() -> Set<String> {
        let request: NSFetchRequest<Planet> = Planet.fetchRequest()
        request.predicate = NSPredicate(format: "keyName != null && keyID != null")
        let context = persistentContainer.viewContext
        do {
            let results = try context.fetch(request)
            let ids: [String] = results.map() { r in
                return r.ipns ?? ""
            }
            debugPrint("got local ipns: \(ids)")
            return Set(ids)
        } catch {
            debugPrint("failed to get planets: \(error)")
        }
        return Set()
    }

    func getFollowingIPNSs() -> Set<String> {
        let request: NSFetchRequest<Planet> = Planet.fetchRequest()
        request.predicate = NSPredicate(format: "keyName == null && keyID == null")
        let context = persistentContainer.viewContext
        do {
            let results = try context.fetch(request)
            let ids: [String] = results.map() { r in
                return r.ipns ?? ""
            }
            debugPrint("got following ipns: \(ids)")
            return Set(ids)
        } catch {
            debugPrint("failed to get planets: \(error)")
        }
        return Set()
    }

    func getLocalPlanets() -> Set<Planet> {
        let request: NSFetchRequest<Planet> = Planet.fetchRequest()
        request.predicate = NSPredicate(format: "keyName != null && keyID != null")
        let context = persistentContainer.viewContext
        do {
            let results = try context.fetch(request)
            let planets: [Planet] = results.map() { r in
                return r
            }
            return Set(planets)
        } catch {
            debugPrint("failed to get planets: \(error)")
        }
        return Set()
    }

    func getFollowingPlanets() -> Set<Planet> {
        let request: NSFetchRequest<Planet> = Planet.fetchRequest()
        request.predicate = NSPredicate(format: "keyName == null && keyID == null")
        let context = persistentContainer.viewContext
        do {
            let results = try context.fetch(request)
            let planets: [Planet] = results.map() { r in
                return r
            }
            return Set(planets)
        } catch {
            debugPrint("failed to get planets: \(error)")
        }
        return Set()
    }

    func removeArticle(_ article: PlanetArticle) {
        let uuid = article.id!
        let planetUUID = article.planetID!
        let context = persistentContainer.viewContext
        context.delete(article)
        do {
            try context.save()
            PlanetManager.shared.destroyArticleDirectory(planetUUID: planetUUID, articleUUID: uuid)
            reportDatabaseStatus()
            DispatchQueue.main.async {
                PlanetStore.shared.selectedArticle = UUID().uuidString
            }
        } catch {
            debugPrint("failed to delete article: \(article), error: \(error)")
        }
    }

    func reportDatabaseStatus() {
        let articlesCountRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PlanetArticle")
        let articlesCount: Int = try! persistentContainer.viewContext.count(for: articlesCountRequest)
        let planetsCountRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Planet")
        let planetsCount: Int = try! persistentContainer.viewContext.count(for: planetsCountRequest)
        debugPrint("context saved, now articles count: \(articlesCount), planets count: \(planetsCount)")
        if planetsCount == 0 && articlesCount > 0 {
            debugPrint("cleanup articles without planets.")
            let context = persistentContainer.viewContext
            let removeRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PlanetArticle")
            do {
                let articles = try context.fetch(removeRequest)
                for a in articles {
                    context.delete(a as! NSManagedObject)
                }
                try context.save()
                reportDatabaseStatus()
            } catch {
                debugPrint("failed to get articles: \(error)")
            }
        }
    }

    func resetDatabase() {
        let context = persistentContainer.viewContext
        let removePlanetRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Planet")
        let removePlanetArticleRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PlanetArticle")
        do {
            let planets = try context.fetch(removePlanetRequest)
            let _ = planets.map() { p in
                context.delete(p as! NSManagedObject)
            }
            let articles = try context.fetch(removePlanetArticleRequest)
            let _ = articles.map() { a in
                context.delete(a as! NSManagedObject)
            }
            try context.save()
        } catch {
            debugPrint("failed to reset database: \(error)")
        }
    }

    private func _articleExists(id: UUID) -> Bool {
        let context = persistentContainer.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "PlanetArticle")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        do {
            let count = try context.count(for: request)
            return count != 0
        } catch {
            return false
        }
    }

    private func _articleExists(link: String, planetID: UUID) -> Bool {
        let context = persistentContainer.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "PlanetArticle")
        let predicate1: NSPredicate = NSPredicate(format: "link == %@", link as CVarArg)
        let predicate2: NSPredicate = NSPredicate(format: "planetID == %@", planetID as CVarArg)
        let predicateCompound = NSCompoundPredicate.init(type: .and, subpredicates: [predicate1, predicate2])
        request.predicate = predicateCompound
        do {
            let count = try context.count(for: request)
            return count != 0
        } catch {
            return false
        }
    }

    private func _planetExists(id: UUID) -> Bool {
        let context = persistentContainer.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Planet")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        do {
            let count = try context.count(for: request)
            return count != 0
        } catch {
            return false
        }
    }
}

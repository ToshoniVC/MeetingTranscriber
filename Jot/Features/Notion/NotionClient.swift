import Foundation

/// Concrete `NotionMeetingWriter` that talks to `api.notion.com` via
/// `URLSession`. No third-party SDK — Notion's REST surface is small enough
/// that hand-rolling against the public docs is cleaner than pulling in a
/// dependency (`coding-instructions.md` §5).
///
/// **Why an actor:** caches per-config database info (title-property name)
/// so we don't refetch on every meeting, and the cache mutation lives off
/// the main actor.
actor NotionClient: NotionMeetingWriter {

    private let session: URLSession

    /// Cache of database descriptions keyed by `databaseId`. Cleared when
    /// the user reconfigures Notion in Settings (`AppSettings` mutation
    /// triggers a `PipelineCoordinator` restart which builds a fresh
    /// `NotionClient`).
    private var databaseCache: [String: NotionDatabaseInfo] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - NotionMeetingWriter

    func createMeetingPage(
        config: NotionConfig,
        meetingName: String,
        transcript: String,
        additionalContext: String
    ) async throws -> NotionPageResult {

        let info = try await fetchOrCacheDatabase(config: config)

        let build = NotionPageBuilder.build(
            databaseId: config.databaseId,
            titlePropertyName: info.titlePropertyName,
            datePropertyName: info.datePropertyName,
            meetingDate: Date(),
            meetingName: meetingName,
            transcript: transcript,
            additionalContext: additionalContext
        )

        // 1) Create the page (returns page ID + child block IDs).
        let response: CreatePageResponse = try await postJSON(
            path: "/v1/pages",
            body: build.createPage,
            config: config,
            timeout: 60
        )

        // 2) If transcript or context overflowed the per-request 100-block
        // limit, locate the right toggle in the response and append the
        // remaining batches.
        if !build.transcriptOverflow.isEmpty {
            let toggleId = try locateToggleId(
                in: response,
                titled: NotionPageBuilder.SectionTitle.meetingTranscript
            )
            for batch in build.transcriptOverflow {
                _ = try await appendChildren(blockId: toggleId, children: batch, config: config)
            }
        }
        if !build.contextOverflow.isEmpty {
            let toggleId = try locateToggleId(
                in: response,
                titled: NotionPageBuilder.SectionTitle.additionalContext
            )
            for batch in build.contextOverflow {
                _ = try await appendChildren(blockId: toggleId, children: batch, config: config)
            }
        }

        guard let pageURL = URL(string: response.url) else {
            throw NotionError.decoding(message: "Created page URL was not parseable: \(response.url)")
        }
        return NotionPageResult(pageId: response.id, url: pageURL)
    }

    func describeDatabase(config: NotionConfig) async throws -> NotionDatabaseInfo {
        try await fetchOrCacheDatabase(config: config)
    }

    // MARK: - Cache lookup

    private func fetchOrCacheDatabase(config: NotionConfig) async throws -> NotionDatabaseInfo {
        if let cached = databaseCache[config.databaseId] {
            return cached
        }
        let info = try await fetchDatabase(config: config)
        databaseCache[config.databaseId] = info
        return info
    }

    private func fetchDatabase(config: NotionConfig) async throws -> NotionDatabaseInfo {
        let response: DatabaseResponse = try await getJSON(
            path: "/v1/databases/\(config.databaseId)",
            config: config,
            timeout: 10
        )

        let title = response.title?
            .compactMap { $0.plain_text }
            .joined() ?? ""

        // Notion guarantees exactly one title property per database. Walk
        // the dictionary to find which key carries `type: "title"`.
        guard let titleKey = response.properties.first(where: { $0.value.type == "title" })?.key else {
            throw NotionError.missingTitleProperty
        }

        // Optional date column — if the database has one, we stamp it
        // with today's date when creating pages. Dictionary order is
        // unspecified; if there are multiple date columns we pick one
        // deterministically by sorted name so reruns are consistent.
        let dateKey = response.properties
            .filter { $0.value.type == "date" }
            .map { $0.key }
            .sorted()
            .first

        return NotionDatabaseInfo(
            title: title,
            titlePropertyName: titleKey,
            datePropertyName: dateKey
        )
    }

    // MARK: - HTTP helpers

    private func postJSON<Body: Encodable, Out: Decodable>(
        path: String,
        body: Body,
        config: NotionConfig,
        timeout: TimeInterval
    ) async throws -> Out {
        var request = try makeRequest(path: path, config: config, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw NotionError.internalInconsistency("Failed to encode request body: \(error.localizedDescription)")
        }
        return try await perform(request)
    }

    private func getJSON<Out: Decodable>(
        path: String,
        config: NotionConfig,
        timeout: TimeInterval
    ) async throws -> Out {
        var request = try makeRequest(path: path, config: config, timeout: timeout)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func appendChildren(
        blockId: String,
        children: [NotionBlock],
        config: NotionConfig
    ) async throws -> AppendChildrenResponse {
        var request = try makeRequest(
            path: "/v1/blocks/\(blockId)/children",
            config: config,
            timeout: 60
        )
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(NotionAppendChildrenRequest(children: children))
        } catch {
            throw NotionError.internalInconsistency("Failed to encode append-children body: \(error.localizedDescription)")
        }
        return try await perform(request)
    }

    private func makeRequest(path: String, config: NotionConfig, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: "https://api.notion.com" + path) else {
            throw NotionError.internalInconsistency("Bad URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.apiVersion, forHTTPHeaderField: "Notion-Version")
        return request
    }

    /// Run the request, map HTTP status to typed errors, decode the body.
    private func perform<Out: Decodable>(_ request: URLRequest) async throws -> Out {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw NotionErrorMapper.transport(error)
        } catch {
            throw NotionError.transport(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NotionError.decoding(message: "Response was not HTTP.")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""
        let retryAfter: TimeInterval? = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0) }

        if let mapped = NotionErrorMapper.error(
            forStatus: http.statusCode,
            bodyHint: bodyString,
            retryAfter: retryAfter
        ) {
            throw mapped
        }

        do {
            return try JSONDecoder().decode(Out.self, from: data)
        } catch {
            throw NotionError.decoding(message: error.localizedDescription)
        }
    }

    /// Walk the create-page response's `children` array to find the
    /// toggle whose first rich-text run matches `title`. Returns the
    /// block ID — the address we PATCH overflow into.
    private func locateToggleId(in response: CreatePageResponse, titled title: String) throws -> String {
        guard let block = response.children?.first(where: { block in
            block.type == "toggle"
                && block.toggle?.rich_text.first?.plain_text == title
        }) else {
            throw NotionError.internalInconsistency("Could not locate toggle '\(title)' in Notion response.")
        }
        return block.id
    }
}

// MARK: - Notion response shapes

private struct DatabaseResponse: Decodable {
    let title: [NotionRichTextRun]?
    let properties: [String: PropertyShape]

    struct PropertyShape: Decodable {
        let type: String
    }
}

/// Parser for the rich-text shape Notion returns. Permissive — only the
/// `plain_text` field is required, the rest is ignored.
private struct NotionRichTextRun: Decodable {
    let plain_text: String?
}

private struct CreatePageResponse: Decodable {
    let id: String
    let url: String
    /// Only populated when Notion echoes the freshly-created children — it
    /// does for `POST /v1/pages` calls that include `children`. Each entry
    /// here carries the block ID we'd PATCH into.
    let children: [BlockShape]?

    struct BlockShape: Decodable {
        let id: String
        let type: String
        let toggle: ToggleShape?

        struct ToggleShape: Decodable {
            let rich_text: [NotionRichTextRun]
        }
    }
}

private struct AppendChildrenResponse: Decodable {
    // The response body isn't useful to us; we only care that the call
    // didn't error. Decoding-as-empty keeps the typed-perform path happy.
    let object: String?
}

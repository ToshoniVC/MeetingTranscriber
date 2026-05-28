import Foundation

/// `Encodable` JSON shapes for the Notion REST API surface we use. Notion's
/// schema is verbose by design — every text fragment is a `rich_text` array
/// of objects with explicit `type: "text"` wrappers — so building it as
/// strongly-typed structs makes the request unambiguous and the tests
/// readable.
///
/// References:
/// - https://developers.notion.com/reference/post-page
/// - https://developers.notion.com/reference/block

// MARK: - Top-level request shapes

/// Request body for `POST /v1/pages`. Includes a database parent, the
/// title property, and the page's child blocks.
struct NotionCreatePageRequest: Encodable, Equatable {
    let parent: NotionParent
    /// Keyed by the database's title-property name (resolved at runtime
    /// from `NotionDatabaseInfo`). Encoded as a dynamic dictionary.
    let properties: [String: NotionPropertyValue]
    let children: [NotionBlock]
}

struct NotionParent: Encodable, Equatable {
    let database_id: String
}

/// Request body for `PATCH /v1/blocks/{id}/children`. Used to append
/// overflow children when a toggle's content exceeds the per-request
/// 100-block limit.
struct NotionAppendChildrenRequest: Encodable, Equatable {
    let children: [NotionBlock]
}

// MARK: - Property values

/// Only the title property is set by Jot; we leave everything else at
/// whatever default the database defines. Modeled as an enum so adding
/// other property types later doesn't require restructuring callers.
enum NotionPropertyValue: Encodable, Equatable {
    case title([NotionRichText])

    enum CodingKeys: String, CodingKey {
        case title
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .title(let runs):
            try c.encode(runs, forKey: .title)
        }
    }
}

// MARK: - Rich text

/// A single run inside a `rich_text` array. Notion caps each run's `content`
/// at 2000 characters; longer text must be split across multiple runs (or
/// — in our case — across multiple paragraph blocks, which reads better in
/// the rendered toggle than a single mega-run).
struct NotionRichText: Encodable, Equatable {
    let type: String
    let text: NotionTextContent

    init(plainText: String) {
        self.type = "text"
        self.text = NotionTextContent(content: plainText)
    }
}

struct NotionTextContent: Encodable, Equatable {
    let content: String
}

// MARK: - Blocks

/// A block in the page tree. Modeled as an enum so we can encode the
/// `{ "object": "block", "type": "toggle", "toggle": { ... } }` shape
/// Notion expects without sprawling property names. Only the block kinds
/// Jot actually uses are represented; add cases as new features need them.
enum NotionBlock: Encodable, Equatable {
    case toggle(title: [NotionRichText], children: [NotionBlock])
    case paragraph(richText: [NotionRichText])

    private enum CodingKeys: String, CodingKey {
        case object, type, toggle, paragraph
    }

    private enum ToggleKeys: String, CodingKey {
        case rich_text, children
    }

    private enum ParagraphKeys: String, CodingKey {
        case rich_text
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("block", forKey: .object)
        switch self {
        case .toggle(let title, let children):
            try c.encode("toggle", forKey: .type)
            var inner = c.nestedContainer(keyedBy: ToggleKeys.self, forKey: .toggle)
            try inner.encode(title, forKey: .rich_text)
            try inner.encode(children, forKey: .children)
        case .paragraph(let richText):
            try c.encode("paragraph", forKey: .type)
            var inner = c.nestedContainer(keyedBy: ParagraphKeys.self, forKey: .paragraph)
            try inner.encode(richText, forKey: .rich_text)
        }
    }
}

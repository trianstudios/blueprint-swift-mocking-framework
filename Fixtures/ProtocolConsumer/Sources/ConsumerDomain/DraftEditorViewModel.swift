/// A mutable document used only by the main-actor view and its view model.
public final class DraftEditorDocument {
    public var title: String

    public init(title: String) { self.title = title }
}

@MainActor
public protocol DraftEditorSurface {
    var document: DraftEditorDocument { get nonmutating set }
    func render(_ document: DraftEditorDocument) async
}

@MainActor
public final class DraftEditorViewModel {
    private let surface: any DraftEditorSurface
    public private(set) var visibleTitle: String?

    public init(surface: any DraftEditorSurface) { self.surface = surface }

    public var currentDocument: DraftEditorDocument { surface.document }

    public func show() async {
        await render(currentDocument)
    }

    public func replace(with document: DraftEditorDocument) async {
        surface.document = document
        await render(document)
    }

    public func rename(to title: String) async {
        let document = currentDocument
        document.title = title
        await render(document)
    }

    private func render(_ document: DraftEditorDocument) async {
        await surface.render(document)
        visibleTitle = document.title
    }
}

import ConsumerDomain

nonisolated func readDocumentOffMainActor(_ model: DraftEditorViewModel) async -> String {
    let document = await model.currentDocument
    return document.title
}

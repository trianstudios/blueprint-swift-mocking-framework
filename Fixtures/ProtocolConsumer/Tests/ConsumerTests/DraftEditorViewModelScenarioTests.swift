import BlueprintMocking
import BlueprintMockingTesting
import ConsumerDomain
import ConsumerDoubles
import Foundation
import Testing

@MainActor
private final class DraftRenderLog {
    var documents: [DraftEditorDocument] = []
    var titles: [String] = []

    func record(_ document: DraftEditorDocument) {
        documents.append(document)
        titles.append(document.title)
    }
}

@Test @MainActor func SYS006_uiViewModelRendersStatefulNonSendableDocuments() async {
    let initial = DraftEditorDocument(title: "Untitled")
    let replacement = DraftEditorDocument(title: "Draft")
    let rendered = DraftRenderLog()
    let mock = DraftEditorSurfaceMock(failureReporter: .swiftTesting) { stubs in
        stubs.store_document(initialValue: initial)
        stubs.render(.any).willAnswer { document in
            await Task.yield()
            MainActor.preconditionIsolated()
            rendered.record(document)
        }
    }
    let model = DraftEditorViewModel(surface: mock)
    #expect(mock.verify.get_document().wasCalled(.never).passed)
    #expect(mock.verify.set_document(.any).wasCalled(.never).passed)
    #expect(mock.verify.render(.any).wasCalled(.never).passed)

    await model.show()
    #expect(model.visibleTitle == "Untitled")
    await model.replace(with: replacement)
    #expect(model.visibleTitle == "Draft")
    await model.rename(to: "Revised draft")

    #expect(model.visibleTitle == "Revised draft")
    #expect(replacement.title == "Revised draft")
    #expect(rendered.titles == ["Untitled", "Draft", "Revised draft"])
    #expect(rendered.documents.count == 3)
    #expect(rendered.documents.first === initial)
    #expect(rendered.documents.dropFirst().allSatisfy { $0 === replacement })
    #expect(mock.verify.get_document(phase: .returned).wasCalled(.exactly(2)).passed)
    #expect(mock.verify.set_document(.identical(to: replacement), phase: .returned).wasCalled(.once).passed)
    #expect(mock.verify.render(.identical(to: replacement), phase: .returned).wasCalled(.exactly(2)).passed)
}

@Test @MainActor func SYS006_uiViewModelReportsIntentionalVerificationAtUserSource() async {
    guard ProcessInfo.processInfo.environment["BLUEPRINT_EXPECT_UI_VIEW_MODEL_FAILURE"] == "1" else { return }

    let initial = DraftEditorDocument(title: "Untitled")
    let replacement = DraftEditorDocument(title: "Draft")
    let mock = DraftEditorSurfaceMock(failureReporter: .swiftTesting) { stubs in
        stubs.store_document(initialValue: initial)
        stubs.render(.any).willReturn(())
    }
    let model = DraftEditorViewModel(surface: mock)
    await model.replace(with: replacement)
    mock.verify.render(.identical(to: replacement), phase: .returned).wasCalled(.never) // UI view-model attribution
}

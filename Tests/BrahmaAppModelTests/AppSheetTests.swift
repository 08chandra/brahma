import Testing
import Foundation
@testable import BrahmaAppModel

@Suite(.scratch) struct AppSheetTests {
    @Test func existingCasesKeepTheirIds() {
        #expect(AppSheet.newCompany.id == "newCompany")
        #expect(AppSheet.hire.id == "hire")
        #expect(AppSheet.newItem.id == "newItem")
    }

    @Test func vacancySheetIds() {
        #expect(AppSheet.vacancy(managerHandle: nil).id == "vacancy:board")
        #expect(AppSheet.vacancy(managerHandle: "cto").id == "vacancy:cto")
        #expect(AppSheet.fillVacancy(handle: "eng-4").id == "fill:eng-4")
        let all: Set<AppSheet> = [.newCompany, .hire, .newItem, .vacancy(managerHandle: nil), .vacancy(managerHandle: "cto"),
                                  .fillVacancy(handle: "eng-4")]
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func sendableAndSelectTarget() {
        let sheet = AppSheet.fillVacancy(handle: "eng-4")
        let read: @Sendable () -> String = { sheet.id }
        #expect(read() == "fill:eng-4")
        #expect(SelectTarget("new-item") == .sheet(.newItem))
        #expect(SelectTarget("hire") == .sheet(.hire))
        #expect(SelectTarget("new-company") == .sheet(.newCompany))
    }
}

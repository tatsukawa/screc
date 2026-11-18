import XCTest

@testable import ScrecKit

final class PickerModelTests: XCTestCase {
    let width: CGFloat = 1800
    let height: CGFloat = 1169

    /// Displays 0 and 1 sit side by side. Display 2 is small and lies to the right of both.
    var displays: [PickDisplay] {
        [
            PickDisplay(index: 0, frame: CGRect(x: 0, y: 0, width: width, height: height), screenFrame: .zero, scale: 2),
            PickDisplay(index: 1, frame: CGRect(x: width, y: 0, width: width, height: height), screenFrame: .zero, scale: 2),
            PickDisplay(index: 2, frame: CGRect(x: 2 * width, y: 100, width: 500, height: 400), screenFrame: .zero, scale: 1),
        ]
    }

    func makeModel(mode: PickMode = .display, pointer: CGPoint = CGPoint(x: 400, y: 300)) -> PickerModel {
        var model = PickerModel(
            displays: displays,
            windows: [
                PickWindow(id: 21, frame: CGRect(x: 200, y: 150, width: 700, height: 450)),  // in front
                PickWindow(id: 22, frame: CGRect(x: 100, y: 100, width: 1200, height: 800)),  // behind it
                PickWindow(id: 23, frame: CGRect(x: width + 200, y: 150, width: 700, height: 450)),  // on display 1
            ],
            pointer: pointer)
        model.mode = mode
        return model
    }

    /// A model in region mode that already holds a region.
    func makeModel(region: CGRect, on display: Int = 0) -> PickerModel {
        var model = makeModel(mode: .region)
        model.region = PickRegion(display: display, rect: region)
        return model
    }

    /// Drags like the mouse would: press at the first point, move through the others, release at the last.
    /// Points are relative to `display`, the display whose overlay received the press.
    func drag(_ model: inout PickerModel, on display: Int = 0, _ points: CGPoint...) {
        let target = displays[display]
        let drag = model.beginDrag(at: points[0], on: target)
        for point in points.dropFirst() { model.continueDrag(drag, to: point, on: target) }
        model.endDrag()
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Selecting

    func testDisplayModeSelectsTheDisplayUnderThePointer() {
        var model = makeModel(mode: .display)
        XCTAssertEqual(model.selection?.target, .display(0))
        XCTAssertEqual(model.selection?.size, CGSize(width: width, height: height))
        model.movePointer(to: point(400, 300), on: displays[1])
        XCTAssertEqual(model.selection?.target, .display(1))
        XCTAssertEqual(model.highlight(on: displays[1]), CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        XCTAssertNil(model.highlight(on: displays[0]))
    }

    func testNothingIsSelectedWhenThePointerIsOutsideEveryDisplay() {
        XCTAssertNil(makeModel(mode: .display, pointer: point(-50, -50)).selection)
    }

    func testWindowModeSelectsTheFrontMostWindowUnderThePointer() {
        var model = makeModel(mode: .window, pointer: point(400, 300))
        XCTAssertEqual(model.selection?.target, .window(21))
        model.pointer = point(1000, 500)  // beside window 21, still inside window 22
        XCTAssertEqual(model.selection?.target, .window(22))
        model.pointer = point(50, 50)  // no window here
        XCTAssertNil(model.selection)
        XCTAssertNotNil(model.hint)
    }

    func testWindowHighlightIsRelativeToItsDisplay() {
        let model = makeModel(mode: .window, pointer: point(width + 400, 300))
        XCTAssertEqual(model.selection?.target, .window(23))
        XCTAssertEqual(model.highlight(on: displays[1]), rect(200, 150, 700, 450))
    }

    func testRegionModeHasNothingToRecordUntilARegionIsDrawn() {
        let model = makeModel(mode: .region)
        XCTAssertNil(model.selection)
        XCTAssertNotNil(model.hint)
        XCTAssertNil(makeModel(region: rect(10, 10, 100, 100)).hint)
    }

    func testSelectionDecidesTheOptions() {
        var options = Options()
        options.select(.region(display: 1, rect: rect(5, 6, 700, 500)))
        XCTAssertEqual(options.display, 1)
        XCTAssertEqual(options.region, rect(5, 6, 700, 500))
        XCTAssertNil(options.window)
        options.select(.window(77))
        XCTAssertEqual(options.window, "77")
        XCTAssertNil(options.region)
        options.select(.display(2))
        XCTAssertEqual(options.display, 2)
        XCTAssertNil(options.window)
    }

    // MARK: Drawing a region

    func testDraggingDrawsARegion() {
        var model = makeModel(mode: .region)
        drag(&model, point(300, 200), point(900, 650))
        XCTAssertEqual(model.region, PickRegion(display: 0, rect: rect(300, 200, 600, 450)))
        XCTAssertEqual(model.selection?.target, .region(display: 0, rect: rect(300, 200, 600, 450)))
    }

    func testDraggingUpAndLeftDrawsTheSameRegion() {
        var model = makeModel(mode: .region)
        drag(&model, point(900, 650), point(300, 200))
        XCTAssertEqual(model.region?.rect, rect(300, 200, 600, 450))
    }

    func testATinyDragIsJustAClickAndLeavesNoRegion() {
        var model = makeModel(mode: .region)
        drag(&model, point(500, 500), point(505, 503))
        XCTAssertNil(model.region)
    }

    func testDrawingIsClippedToTheDisplay() {
        var model = makeModel(mode: .region)
        drag(&model, point(width - 100, 400), point(width + 300, 600))
        XCTAssertEqual(model.region?.rect.maxX, width)
    }

    func testDraggingOutsideTheRegionDrawsANewOne() {
        var model = makeModel(region: rect(300, 200, 600, 450))
        drag(&model, point(1200, 800), point(1500, 1000))
        XCTAssertEqual(model.region?.rect, rect(1200, 800, 300, 200))
    }

    func testDrawingOnAnotherDisplayReplacesTheRegion() {
        var model = makeModel(region: rect(300, 200, 600, 450), on: 0)
        drag(&model, on: 1, point(50, 60), point(350, 260))
        XCTAssertEqual(model.region, PickRegion(display: 1, rect: rect(50, 60, 300, 200)))
    }

    func testAClickInsideTheRegionKeepsIt() {
        var model = makeModel(region: rect(300, 200, 600, 450))
        drag(&model, point(600, 400), point(600, 400))
        XCTAssertEqual(model.region?.rect, rect(300, 200, 600, 450))
    }

    // MARK: Moving a region

    func testDraggingInsideMovesTheRegion() {
        var model = makeModel(region: rect(300, 200, 600, 450))
        drag(&model, point(600, 400), point(700, 450))
        XCTAssertEqual(model.region?.rect, rect(400, 250, 600, 450))
    }

    func testMovingStopsAtTheDisplayEdgesAndKeepsTheSize() {
        var model = makeModel(region: rect(300, 200, 600, 450))
        drag(&model, point(600, 400), point(-500, -500))
        XCTAssertEqual(model.region?.rect, rect(0, 0, 600, 450))
        drag(&model, point(300, 200), point(width + 500, height + 500))
        XCTAssertEqual(model.region?.rect, rect(width - 600, height - 450, 600, 450))
    }

    func testARegionCanBeCarriedToAnotherDisplay() {
        var model = makeModel(region: rect(300, 200, 600, 450))
        drag(&model, point(600, 400), point(1000, 400), point(width + 700, 500))
        XCTAssertEqual(model.region, PickRegion(display: 1, rect: rect(400, 300, 600, 450)))
        XCTAssertEqual(model.highlight(on: displays[1]), rect(400, 300, 600, 450))
        XCTAssertNil(model.highlight(on: displays[0]))
    }

    func testARegionIsKeptInsideTheDisplayItIsDroppedOn() {
        var model = makeModel(region: rect(300, 200, 600, 450))
        drag(&model, point(600, 400), point(width + 10, 500))
        XCTAssertEqual(model.region?.display, 1)
        XCTAssertEqual(model.region?.rect.minX, 0)
    }

    func testARegionShrinksToFitASmallerDisplayAndRegrowsWhenCarriedBack() {
        let region = rect(300, 200, 600, 450)
        var model = makeModel(region: region)
        let origin = displays[0]
        let grab = model.beginDrag(at: point(600, 400), on: origin)

        model.continueDrag(grab, to: point(2 * width + 200, 300), on: origin)  // onto the 500x400 display
        XCTAssertEqual(model.region?.display, 2)
        XCTAssertEqual(model.region?.rect.size, CGSize(width: 500, height: 400))

        model.continueDrag(grab, to: point(width + 800, 500), on: origin)  // and back to display 1
        XCTAssertEqual(model.region?.display, 1)
        XCTAssertEqual(model.region?.rect.size, region.size)
    }

    func testARegionCanBeCarriedBackToTheFirstDisplay() {
        var model = makeModel(region: rect(500, 300, 600, 450), on: 1)
        drag(&model, on: 1, point(800, 500), point(-400, 400))
        XCTAssertEqual(model.region?.display, 0)
        XCTAssertEqual(model.region?.rect, rect(width - 700, 200, 600, 450))
    }

    // MARK: Resizing a region

    func testCornersAndEdgesResizeTheRegion() {
        var model = makeModel(region: rect(400, 250, 600, 450))

        drag(&model, point(1000, 700), point(1100, 800))  // bottom-right corner
        XCTAssertEqual(model.region?.rect, rect(400, 250, 700, 550))

        drag(&model, point(400, 250), point(300, 200))  // top-left corner: the opposite corner stays put
        XCTAssertEqual(model.region?.rect, rect(300, 200, 800, 600))

        drag(&model, point(700, 200), point(750, 100))  // top edge: only the height changes
        XCTAssertEqual(model.region?.rect, rect(300, 100, 800, 700))

        drag(&model, point(1100, 400), point(1000, 300))  // right edge: only the width changes
        XCTAssertEqual(model.region?.rect, rect(300, 100, 700, 700))
    }

    func testDraggingAnEdgePastTheOppositeEdgeFlipsTheRegion() {
        var model = makeModel(region: rect(300, 100, 700, 700))
        drag(&model, point(300, 400), point(1200, 400))
        XCTAssertEqual(model.region?.rect, rect(1000, 100, 200, 700))
    }

    func testResizingIsClippedToTheDisplay() {
        var model = makeModel(region: rect(1000, 100, 200, 700))
        drag(&model, point(1100, 800), point(1100, height + 300))
        XCTAssertEqual(model.region?.rect, rect(1000, 100, 200, height - 100))
    }

    func testAnEdgeCanBeGrabbedJustOutsideTheRegion() {
        var model = makeModel(region: rect(1000, 100, 200, 700))
        drag(&model, point(997, 400), point(990, 400))
        XCTAssertEqual(model.region?.rect, rect(990, 100, 210, 700))
    }

    func testGrips() {
        let region = rect(100, 100, 200, 100)
        XCTAssertEqual(PickerModel.grip(at: point(200, 150), in: region)?.h, 0)  // inside
        XCTAssertEqual(PickerModel.grip(at: point(200, 150), in: region)?.v, 0)
        XCTAssertEqual(PickerModel.grip(at: point(100, 150), in: region)?.h, -1)  // left edge
        XCTAssertEqual(PickerModel.grip(at: point(300, 200), in: region)?.h, 1)  // bottom-right corner
        XCTAssertEqual(PickerModel.grip(at: point(300, 200), in: region)?.v, 1)
        XCTAssertEqual(PickerModel.grip(at: point(200, 92), in: region)?.v, -1)  // just above the top edge
        XCTAssertNil(PickerModel.grip(at: point(200, 50), in: region))  // away from the region
    }
}

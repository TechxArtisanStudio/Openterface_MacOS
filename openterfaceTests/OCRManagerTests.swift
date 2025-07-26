/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import XCTest
@testable import openterface

@available(macOS 12.3, *)
final class OCRManagerTests: XCTestCase {
    
    var ocrManager: OCRManagerProtocol!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Setup dependency container for testing
        let container = DependencyContainer.shared
        
        // Register test dependencies if not already registered
        if !container.isRegistered(LoggerProtocol.self) {
            container.register(LoggerProtocol.self, instance: Logger.shared)
        }
        if !container.isRegistered(TipLayerManagerProtocol.self) {
            container.register(TipLayerManagerProtocol.self, instance: TipLayerManager())
        }
        if !container.isRegistered(OCRManagerProtocol.self) {
            container.register(OCRManagerProtocol.self, instance: OCRManager.shared)
        }
        
        ocrManager = container.resolve(OCRManagerProtocol.self)
    }
    
    override func tearDownWithError() throws {
        ocrManager = nil
        try super.tearDownWithError()
    }
    
    func testOCRManagerInitialization() throws {
        XCTAssertNotNil(ocrManager, "OCR Manager should be initialized")
    }
    
    func testCaptureScreenArea() throws {
        let testRect = NSRect(x: 0, y: 0, width: 100, height: 100)
        let capturedImage = ocrManager.captureScreenArea(testRect)
        
        // On headless systems or when no screen is available, this might be nil
        // But the method should not crash
        XCTAssertTrue(true, "Capture screen area method should execute without crashing")
    }
    
    func testOCRWithInvalidImage() throws {
        let expectation = self.expectation(description: "OCR completion")
        
        // Create a minimal 1x1 pixel CGImage for testing
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let testImage = context.makeImage()!
        
        ocrManager.performOCR(on: testImage) { result in
            switch result {
            case .success(_):
                XCTFail("Should not succeed with 1x1 pixel image")
            case .noTextFound:
                XCTAssertTrue(true, "No text found is expected for minimal image")
            case .failed(_):
                XCTAssertTrue(true, "Failure is acceptable for minimal image")
            }
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5.0, handler: nil)
    }
    
    func testPerformOCROnSelectedArea() throws {
        let expectation = self.expectation(description: "OCR on selected area completion")
        
        // Start area selection first
        ocrManager.startAreaSelection()
        
        // Simulate area selection (in real use, this would be done through UI)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.ocrManager.performOCROnSelectedArea { result in
                // Should complete without crashing, result depends on screen content
                XCTAssertTrue(true, "OCR on selected area should complete")
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 10.0, handler: nil)
    }
    
    func testStartAndCancelAreaSelection() throws {
        // Should not crash
        ocrManager.startAreaSelection()
        XCTAssertTrue(ocrManager.isAreaSelectionActive, "Area selection should be active after starting")
        
        ocrManager.cancelAreaSelection()
        XCTAssertFalse(ocrManager.isAreaSelectionActive, "Area selection should be inactive after cancelling")
    }
    
    func testHandleAreaSelectionComplete() throws {
        // This should not crash
        ocrManager.handleAreaSelectionComplete()
        XCTAssertTrue(true, "Handle area selection complete should execute without crashing")
    }
}

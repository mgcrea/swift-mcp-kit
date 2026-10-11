import Foundation
import Testing

@testable import MCPKit

@Suite("ToolResult")
struct ToolResultTests {
  private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  @Test("An image goes inline as base64, after its lede", arguments: MCPVersion.allCases)
  func imageIsInline(version: MCPVersion) {
    let result = ToolResult.image("A plan.", data: png, mimeType: "image/png", ["width": 2])
    let blocks = result.json(for: version)["content"]?.arrayValue ?? []
    #expect(blocks[0]["type"] == "text")
    #expect(blocks[1]["type"] == "image")
    #expect(blocks[1]["mimeType"] == "image/png")
    #expect(blocks[1]["data"] == .string(png.base64EncodedString()))
    #expect(result.json(for: version)["structuredContent"]?["width"] == 2)
  }

  @Test("An image is not text")
  func textLeavesImagesOut() {
    let result = ToolResult.image("A plan.", data: png, mimeType: "image/png")
    #expect(result.text == "A plan.")
    #expect(!result.isError)
  }
}

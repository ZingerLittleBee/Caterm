import Foundation

@MainActor
public protocol SnippetDispatchTarget: AnyObject {
	func paste(_ text: String)
	func run(_ text: String)
}

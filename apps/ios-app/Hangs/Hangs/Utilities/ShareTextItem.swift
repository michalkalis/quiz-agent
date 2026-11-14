//
//  ShareTextItem.swift
//  Hangs
//
//  #232: a message for the share sheet whose header shows a clean title and
//  the link, instead of the first words of the message.
//

import LinkPresentation
import UIKit

final class ShareTextItem: NSObject, UIActivityItemSource {
    let text: String
    private let title: String
    private let url: URL

    init(text: String, title: String, url: URL) {
        self.text = text
        self.title = title
        self.url = url
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(_: UIActivityViewController, itemForActivityType _: UIActivity.ActivityType?) -> Any? {
        text
    }

    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }
}

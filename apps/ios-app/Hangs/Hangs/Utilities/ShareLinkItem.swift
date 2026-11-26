//
//  ShareLinkItem.swift
//  Hangs
//
//  #232 / #249.6: the link of a shared quiz as its own share item, next to
//  the message text. Two items (a String and this URL) are what lets chat
//  apps (iMessage, WhatsApp, Messenger) show the text and a rich link
//  preview; one long string with the link inside turns into a .txt file in
//  some of them. The share sheet's header shows the Trubbo mark, a clean
//  title, the link and, for a daily challenge, the score card.
//

import LinkPresentation
import UIKit

final class ShareLinkItem: NSObject, UIActivityItemSource {
    let url: URL
    private let title: String
    private let image: UIImage?

    init(url: URL, title: String, image: UIImage? = nil) {
        self.url = url
        self.title = title
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_: UIActivityViewController, itemForActivityType _: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        if let mark = UIImage(named: "TrubboMascot") {
            metadata.iconProvider = NSItemProvider(object: mark)
        }
        if let image {
            metadata.imageProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}

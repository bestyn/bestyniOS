//
//  PrivatePhotoVideoOutcomeCell.swift
//  neighbourhood
//
//  Created by Dioksa on 08.07.2020.
//  Copyright © 2020 GBKSoft. All rights reserved.
//

import UIKit
import AVKit

final class PrivatePhotoVideoOutcomeCell: BaseChatMediaCell {
    override var isIncome: Bool { false }

    @IBOutlet private weak var sentStateImageView: UIImageView!

    override func fillSpecificData(from message: PrivateChatMessageModel) {
        super.fillSpecificData(from: message)
        sentStateImageView.image = message.isRead ? R.image.sent_read_icon() : R.image.sent_unread_icon()
    }
}

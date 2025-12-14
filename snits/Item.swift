//
//  Item.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

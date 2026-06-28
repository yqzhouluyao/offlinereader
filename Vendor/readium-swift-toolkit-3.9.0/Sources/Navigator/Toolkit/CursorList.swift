//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// A `List` with a mutable cursor index.
struct CursorList<Element> {
    private let list: [Element]
    private let startIndex: Int

    init(list: [Element] = [], startIndex: Int = 0) {
        self.list = list
        self.startIndex = startIndex
    }

    private var index: Int?

    /// Returns the current element.
    mutating func current() -> Element? {
        moveAndGet(index ?? startIndex)
    }

    /// Moves the cursor backward and returns the element, or null when reaching the beginning.
    mutating func previous() -> Element? {
        moveAndGet(index.map { $0 - 1 } ?? startIndex)
    }

    /// Moves the cursor forward and returns the element, or null when reaching the end.
    mutating func next() -> Element? {
        moveAndGet(index.map { $0 + 1 } ?? startIndex)
    }

    /// Returns the next elements after the current cursor without moving it.
    func nextItems(limit: Int) -> [Element] {
        guard limit > 0 else {
            return []
        }

        let currentIndex = index ?? startIndex
        let firstIndex = currentIndex + 1
        guard list.indices.contains(firstIndex) else {
            return []
        }

        let lastIndex = min(firstIndex + limit, list.endIndex)
        return Array(list[firstIndex ..< lastIndex])
    }

    private mutating func moveAndGet(_ index: Int) -> Element? {
        guard list.indices.contains(index) else {
            return nil
        }
        self.index = index
        return list[index]
    }
}

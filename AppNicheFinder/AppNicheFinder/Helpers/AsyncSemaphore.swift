//
//  AsyncSemaphore.swift
//  AppNicheFinder
//
//  Простой async-семафор для лимита одновременных задач.
//

import Foundation

actor AsyncSemaphore {
    private let limit: Int
    private var inUse: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func wait() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            inUse = max(0, inUse - 1)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AhoCorasickTrie.swift
//  Onit
//
//  Aho-Corasick automaton over CTC token IDs.
//  Supports multi-keyword matching in a single forward pass - all keywords
//  are matched simultaneously, O(keywords) build cost amortised across the
//  full recording.
//
//  Usage:
//    var trie = AhoCorasickTrie()
//    trie.insert(tokens: [62, 14], keywordID: 0)   // "onit" BPE tokens
//    trie.build()                                   // compute fail links
//    let next = trie.advance(from: 0, token: 62)   // follow transition
//

struct AhoCorasickTrie {

    // MARK: - Node

    struct Node {
        /// token → child node index
        var children: [Int: Int] = [:]
        /// Aho-Corasick fail link (longest proper suffix that is also a prefix)
        var failLink: Int = 0
        /// Shortcut to nearest ancestor end-node reachable via fail chain (-1 = none)
        var outputLink: Int = -1
        /// Depth from root (= number of tokens matched to reach this node)
        var depth: Int = 0
        /// Keyword ID if this is an end node, -1 otherwise
        var keywordID: Int = -1

        var isEnd: Bool { keywordID >= 0 }
    }

    // MARK: - State

    private(set) var nodes: [Node] = [Node()]   // root at index 0
    private(set) var keywords: [[Int]] = []
    private(set) var isBuilt: Bool = false

    // MARK: - Build

    mutating func insert(tokens: [Int], keywordID: Int) {
        precondition(!isBuilt, "Cannot insert after build()")
        guard !tokens.isEmpty else { return }
        var state = 0
        for token in tokens {
            if let next = nodes[state].children[token] {
                state = next
            } else {
                let idx = nodes.count
                var child = Node()
                child.depth = nodes[state].depth + 1
                nodes[state].children[token] = idx
                nodes.append(child)
                state = idx
            }
        }
        nodes[state].keywordID = keywordID
        keywords.append(tokens)
    }

    /// BFS pass to set fail links and output links on every node.
    /// Must be called once after all `insert` calls, before any `advance`.
    mutating func build() {
        var queue: [Int] = []
        // Depth-1 nodes fail directly to root
        for child in nodes[0].children.values {
            nodes[child].failLink = 0
            queue.append(child)
        }
        while !queue.isEmpty {
            let curr = queue.removeFirst()
            for (token, child) in nodes[curr].children {
                // Follow fail links from parent until we find a node with this token child
                var failState = nodes[curr].failLink
                while failState != 0 && nodes[failState].children[token] == nil {
                    failState = nodes[failState].failLink
                }
                let fl = nodes[failState].children[token] ?? 0
                nodes[child].failLink = (fl == child) ? 0 : fl
                // Output link: nearest fail-chain ancestor that is an end node
                let parentFL = nodes[child].failLink
                nodes[child].outputLink = nodes[parentFL].isEnd ? parentFL : nodes[parentFL].outputLink
                queue.append(child)
            }
        }
        isBuilt = true
    }

    // MARK: - Query

    /// Advance from `state` on `token`, using fail links if no direct child.
    /// Returns the new state index.
    func advance(from state: Int, token: Int) -> Int {
        var s = state
        while s != 0 && nodes[s].children[token] == nil {
            s = nodes[s].failLink
        }
        return nodes[s].children[token] ?? 0
    }

    func isEnd(_ state: Int) -> Bool { nodes[state].isEnd }
    func keywordID(at state: Int) -> Int { nodes[state].keywordID }
    func depth(of state: Int) -> Int { nodes[state].depth }

    /// All keyword IDs reachable from `state` via output links (for overlapping matches).
    func allMatches(at state: Int) -> [Int] {
        var results: [Int] = []
        if nodes[state].isEnd { results.append(nodes[state].keywordID) }
        var link = nodes[state].outputLink
        while link >= 0 {
            results.append(nodes[link].keywordID)
            link = nodes[link].outputLink
        }
        return results
    }
}

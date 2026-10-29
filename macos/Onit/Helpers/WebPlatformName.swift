// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WebPlatformName.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-08.
//

import Foundation

private let knownSecondLevelCountryCodeDomains: Set<String> = ["co.uk","co.jp", "co.kr", "co.in", "co.nz", "co.za", "co.id", "co.th", "com.au", "com.br", "com.mx", "com.tr", "com.sg", "com.ar", "com.tw", "com.hk", "com.my", "com.ph", "com.pk", "com.co", "com.ng", "com.eg", "com.vn", "com.ua", "com.sa", "com.pe", "com.bd", "org.uk", "net.au", "net.br", "ne.jp", "or.jp", "ac.uk", "ac.jp"]

func getWebPlatformName(from urlString: String) -> String? {
    let safeUrlString = urlString.lowercased()

    let normalizedString: String

    if safeUrlString.hasPrefix("http://") || safeUrlString.hasPrefix("https://") {
        normalizedString = safeUrlString
    } else {
        normalizedString = "https://\(safeUrlString)"
    }

    guard let url = URL(string: normalizedString),
          let urlHost = url.host?.lowercased()
    else {
        return nil
    }

    let normalizedUrlHost = urlHost.hasPrefix("www.") ? String(urlHost.dropFirst(4)) : urlHost

    let normalizedUrlHostParts = normalizedUrlHost.split(separator: ".").map(String.init)

    guard normalizedUrlHostParts.count >= 2
    else {
        return normalizedUrlHostParts.first
    }

    /// Checking for potential country-code domains (e.g. `co.uk`, `co.au`, etc.).
    let lastTwoHostParts = "\(normalizedUrlHostParts[normalizedUrlHostParts.count - 2]).\(normalizedUrlHostParts.last!)"

    if knownSecondLevelCountryCodeDomains.contains(lastTwoHostParts),
       normalizedUrlHostParts.count >= 3
    {
        return normalizedUrlHostParts[normalizedUrlHostParts.count - 3]
    }

    return normalizedUrlHostParts[normalizedUrlHostParts.count - 2]
}

//
//  PlatformNavigationStack.swift
//  Aidoku
//
//  Created by Skitty on 10/6/23.
//

import SwiftUI

// uses navigationstack for newer ios, and uses a custom path for macos (in order to have animations)
struct PlatformNavigationStack<Content: View>: View {
    @ContentBuilder let content: Content

    var body: some View {
        NavigationStack {
            content
        }
    }
}

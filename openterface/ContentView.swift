/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import SwiftUI

struct ContentView: View {
    @StateObject var viewModel = PlayerViewModel() // Ensures the view model is initialized once
    
    @Environment(\.controlActiveState) var controlActiveState
    
    init() {
    }

    var body: some View {
        VStack {
            PlayerContainerView(captureSession: viewModel.captureSession)
                .onTapGesture {
                    // click in windows
                    if AppStatus.isExit {
                        AppStatus.isExit = false
                    }
                }
        }
        .onAppear {
            viewModel.checkAuthorization() // Perform authorization check when the view appears
        }
    }
}

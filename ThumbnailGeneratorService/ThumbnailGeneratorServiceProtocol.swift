//
//  ThumbnailGeneratorServiceProtocol.swift
//  photo2
//
//  Created by David Xiao on 3/9/25.
//

import Foundation

// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol ThumbnailGeneratorServiceProtocol {
    
    // Replace the API of this protocol with an API appropriate to the service you are vending.
    func performCalculation(firstNumber: Int, secondNumber: Int, with reply: @escaping (Int) -> Void)
} 
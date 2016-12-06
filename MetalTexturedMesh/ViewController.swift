/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    View controller class that manages the MTKView and renderer.
*/

import MetalKit
import Cocoa

class ViewController: NSViewController {

    var renderer: Renderer!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let metalView = self.view as! MTKView
        
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (aEvent) -> NSEvent! in
            self.keyDown(with: aEvent)
            return aEvent
        }
        
        // We initialize our renderer object with the MTKView it will be drawing into
        renderer = Renderer(mtkView:metalView)
    }
    
    override func keyDown(with event: NSEvent) {
        print("key = " + (event.charactersIgnoringModifiers
            ?? ""))
        if (event.charactersIgnoringModifiers == "w") {
            renderer.camPos += Float(renderer.camSpeed) * float3(0, 0, -1);
        }
        if (event.charactersIgnoringModifiers == "s") {
            renderer.camPos += Float(renderer.camSpeed) * float3(0, 0, 1);
        }
        if (event.charactersIgnoringModifiers == "a") {
            renderer.camPos += Float(renderer.camSpeed) * float3(-1, 0, 0);
        }
        if (event.charactersIgnoringModifiers == "d") {
            renderer.camPos += Float(renderer.camSpeed) * float3(1, 0, 0);
        }
    }
}

import UIKit
import SwiftUI
import SwiftTerm
import ios_system
// Assuming python3_ios automatically registers when linked, or we may need to initialize it.
// ios_system's initializeEnvironment() usually finds available frameworks.

struct TerminalViewWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TerminalViewController {
        return TerminalViewController()
    }
    
    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {}
}

class TerminalViewController: UIViewController, TerminalViewDelegate {
    var terminalView: TerminalView!
    var stdinPipe: [Int32] = [0, 0]
    var stdoutPipe: [Int32] = [0, 0]
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        terminalView = TerminalView(frame: view.bounds)
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminalView.delegate = self
        view.addSubview(terminalView)
        
        // Initialize ios_system
        initializeEnvironment()
        
        // Setup working directory
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
        ios_setDirectoryURL(URL(fileURLWithPath: docDir))
        FileManager.default.changeCurrentDirectoryPath(docDir)
        
        setupSystem()
        startIOThreads()
        
        terminalView.feed(text: "Starting Python Environment...\r\n")
        
        // Run python in background
        DispatchQueue.global(qos: .userInitiated).async {
            // Environment variables
            setenv("TERM", "xterm-256color", 1)
            setenv("PYTHONHOME", Bundle.main.resourcePath, 1) // Often needed for python_ios, but we'll see if it auto-configures
            
            // Execute python. ios_system takes the command string.
            ios_system("python3")
            
            DispatchQueue.main.async {
                self.terminalView.feed(text: "\r\n[Process exited]\r\n")
            }
        }
    }
    
    func setupSystem() {
        pipe(&stdinPipe)
        pipe(&stdoutPipe)
        
        // Make stdout/stderr unbuffered or block buffered? For a pty it's usually unbuffered or line buffered.
        // ios_system might use setvbuf. We provide FILE pointers.
        let stdinFile = fdopen(stdinPipe[0], "r")
        let stdoutFile = fdopen(stdoutPipe[1], "w")
        
        // Disable buffering on our stdout pipe end if possible
        setvbuf(stdoutFile, nil, _IONBF, 0)
        
        ios_setStreams(stdinFile, stdoutFile, stdoutFile)
    }
    
    func startIOThreads() {
        // Read from stdoutPipe[0] and feed to terminalView
        DispatchQueue.global(qos: .background).async {
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            while true {
                let bytesRead = read(self.stdoutPipe[0], buffer, bufferSize)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    if let string = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            // SwiftTerm uses carriage returns
                            let formatted = string.replacingOccurrences(of: "\n", with: "\r\n")
                            self.terminalView.feed(text: formatted)
                        }
                    }
                } else if bytesRead <= 0 {
                    break
                }
            }
        }
    }
    
    // MARK: - TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        // Write user input to stdin pipe
        write(stdinPipe[1], bytes, bytes.count)
    }
    
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrollPositionChanged(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
}

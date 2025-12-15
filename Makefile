# Efficiency Cockpit - macOS Productivity Tracker
# Build commands for the project

.PHONY: all build run clean xcode spm install help

# Default target
all: build

# Build using Swift Package Manager
build:
	swift build

# Build release version
release:
	swift build -c release

# Run the app (requires building first)
run: build
	./.build/debug/EfficiencyCockpit

# Run MCP server (for testing)
run-mcp: build
	./.build/debug/EfficiencyCockpitMCPServer

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf DerivedData
	rm -rf *.xcodeproj

# Generate Xcode project using xcodegen
xcode:
	@if command -v xcodegen >/dev/null 2>&1; then \
		xcodegen generate; \
		echo "Xcode project generated. Open EfficiencyCockpit.xcodeproj"; \
	else \
		echo "xcodegen not found. Install with: brew install xcodegen"; \
		echo "Or open Package.swift directly in Xcode"; \
	fi

# Open in Xcode using Package.swift
spm:
	open Package.swift

# Install xcodegen if not present
install-xcodegen:
	brew install xcodegen

# Build and create app bundle
app: release
	@echo "Creating app bundle..."
	@mkdir -p "build/Efficiency Cockpit.app/Contents/MacOS"
	@mkdir -p "build/Efficiency Cockpit.app/Contents/Resources"
	@cp .build/release/EfficiencyCockpit "build/Efficiency Cockpit.app/Contents/MacOS/"
	@cp .build/release/EfficiencyCockpitMCPServer "build/Efficiency Cockpit.app/Contents/MacOS/"
	@cp EfficiencyCockpit/Info.plist "build/Efficiency Cockpit.app/Contents/"
	@echo "App bundle created at: build/Efficiency Cockpit.app"

# Install to /Applications (requires sudo for system /Applications)
install: app
	@echo "Installing to ~/Applications..."
	@mkdir -p ~/Applications
	@rm -rf "~/Applications/Efficiency Cockpit.app"
	@cp -r "build/Efficiency Cockpit.app" ~/Applications/
	@echo "Installed to ~/Applications/Efficiency Cockpit.app"

# Show help
help:
	@echo "Efficiency Cockpit Build Commands"
	@echo "=================================="
	@echo ""
	@echo "  make build        - Build debug version with SPM"
	@echo "  make release      - Build release version with SPM"
	@echo "  make run          - Build and run the app"
	@echo "  make run-mcp      - Build and run MCP server"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make xcode        - Generate Xcode project (requires xcodegen)"
	@echo "  make spm          - Open Package.swift in Xcode"
	@echo "  make app          - Build release app bundle"
	@echo "  make install      - Install to ~/Applications"
	@echo "  make help         - Show this help"
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make spm       - Opens project in Xcode"
	@echo "  2. Build & Run in Xcode (Cmd+R)"
	@echo ""
	@echo "Or with xcodegen:"
	@echo "  1. brew install xcodegen"
	@echo "  2. make xcode"
	@echo "  3. open EfficiencyCockpit.xcodeproj"

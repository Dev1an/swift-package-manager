/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */


import Basics
import PackageLoading
import PackageModel
import SourceControl
import TSCBasic
import Workspace
import XCTest

public final class MockWorkspace {
    let sandbox: AbsolutePath
    let fs: FileSystem
    public let httpClient: HTTPClient
    public let archiver: MockArchiver
    public let checksumAlgorithm: MockHashAlgorithm
    let roots: [MockPackage]
    let packages: [MockPackage]
    public let mirrors: DependencyMirrors
    let identityResolver: IdentityResolver
    public var manifestLoader: MockManifestLoader
    public var repoProvider: InMemoryGitRepositoryProvider
    public let delegate = MockWorkspaceDelegate()
    let toolsVersion: ToolsVersion
    let resolverUpdateEnabled: Bool

    public init(
        sandbox: AbsolutePath,
        fs: FileSystem,
        httpClient: HTTPClient? = nil,
        archiver: MockArchiver = MockArchiver(),
        checksumAlgorithm: MockHashAlgorithm = MockHashAlgorithm(),
        mirrors: DependencyMirrors? = nil,
        roots: [MockPackage],
        packages: [MockPackage],
        toolsVersion: ToolsVersion = ToolsVersion.currentToolsVersion,
        resolverUpdateEnabled: Bool = true
    ) throws {
        self.sandbox = sandbox
        self.fs = fs
        self.httpClient = httpClient ?? HTTPClient.mock(fileSystem: fs)
        self.archiver = archiver
        self.checksumAlgorithm = checksumAlgorithm
        self.mirrors = mirrors ?? DependencyMirrors()
        self.identityResolver = DefaultIdentityResolver(locationMapper: self.mirrors.effectiveURL(for:))
        self.roots = roots
        self.packages = packages

        self.manifestLoader = MockManifestLoader(manifests: [:])
        self.repoProvider = InMemoryGitRepositoryProvider()
        self.toolsVersion = toolsVersion
        self.resolverUpdateEnabled = resolverUpdateEnabled

        try self.create()
    }

    private var rootsDir: AbsolutePath {
        return self.sandbox.appending(component: "roots")
    }

    public var packagesDir: AbsolutePath {
        return self.sandbox.appending(component: "pkgs")
    }

    public var artifactsDir: AbsolutePath {
        return self.sandbox.appending(components: ".build", "artifacts")
    }

    public func urlForPackage(withName name: String) -> String {
        return self.packagesDir.appending(RelativePath(name)).pathString
    }

    private func url(for package: MockPackage) -> String {
        return self.packagesDir.appending(RelativePath(package.path ?? package.name)).pathString
    }

    private func create() throws {
        // Remove the sandbox if present.
        try self.fs.removeFileTree(self.sandbox)

        // Create directories.
        try self.fs.createDirectory(self.sandbox, recursive: true)
        try self.fs.createDirectory(self.rootsDir)
        try self.fs.createDirectory(self.packagesDir)

        var manifests: [MockManifestLoader.Key: Manifest] = [:]

        func create(package: MockPackage, basePath: AbsolutePath, packageKind: PackageReference.Kind) throws {
            let packagePath = basePath.appending(RelativePath(package.path ?? package.name))

            let packageLocation = (packageKind == .root ? packagePath : self.packagesDir.appending(RelativePath(package.path ?? package.name))).pathString
            let specifier = RepositorySpecifier(url: packageLocation)

            // Create targets on disk.
            let repo = self.repoProvider.specifierMap[specifier] ?? InMemoryGitRepository(path: packagePath, fs: self.fs as! InMemoryFileSystem)
            let repoSourcesDir = AbsolutePath("/Sources")
            for target in package.targets {
                let repoTargetDir = repoSourcesDir.appending(component: target.name)
                try repo.createDirectory(repoTargetDir, recursive: true)
                try repo.writeFileContents(repoTargetDir.appending(component: "file.swift"), bytes: "")
            }
            let toolsVersion = package.toolsVersion ?? .currentToolsVersion
            let repoManifestPath = AbsolutePath.root.appending(component: Manifest.filename)
            try repo.writeFileContents(repoManifestPath, bytes: "")
            try rewriteToolsVersionSpecification(toDefaultManifestIn: .root, specifying: toolsVersion, fileSystem: repo)
            try repo.commit()

            let versions: [String?] = packageKind == .remote ? package.versions : [nil]
            let manifestPath = packagePath.appending(component: Manifest.filename)
            for version in versions {
                let v = version.flatMap(Version.init(_:))
                manifests[.init(url: packageLocation, version: v)] = Manifest(
                    name: package.name,
                    path: manifestPath,
                    packageKind: packageKind,
                    packageLocation: packageLocation,
                    platforms: package.platforms,
                    version: v,
                    toolsVersion: toolsVersion,
                    dependencies: package.dependencies.map { $0.convert(baseURL: packagesDir, identityResolver: self.identityResolver) },
                    products: package.products.map { ProductDescription(name: $0.name, type: .library(.automatic), targets: $0.targets) },
                    targets: try package.targets.map { try $0.convert() }
                )
                if let version = version {
                    try repo.tag(name: version)
                }
            }

            self.repoProvider.add(specifier: specifier, repository: repo)
        }

        // Create root packages.
        for package in self.roots {
            try create(package: package, basePath: self.rootsDir, packageKind: .root)
        }

        // Create dependency packages.
        for package in self.packages {
            try create(package: package, basePath: self.packagesDir, packageKind: .remote)
        }

        self.manifestLoader = MockManifestLoader(manifests: manifests)
    }

    public func getOrCreateWorkspace() throws -> Workspace {
        if let workspace = self._workspace {
            return workspace
        }

        let workspace = try Workspace(
            fileSystem: self.fs,
            location: .init(
                workingDirectory: self.sandbox.appending(component: ".build"),
                editsDirectory: self.sandbox.appending(component: "edits"),
                resolvedVersionsFile: self.sandbox.appending(component: "Package.resolved"),
                sharedCacheDirectory: self.fs.swiftPMCacheDirectory,
                sharedConfigurationDirectory: self.fs.swiftPMConfigDirectory
            ),
            mirrors: self.mirrors,
            customToolsVersion: self.toolsVersion,
            customManifestLoader: self.manifestLoader,
            customRepositoryProvider: self.repoProvider,
            customIdentityResolver: self.identityResolver,
            customHTTPClient: self.httpClient,
            customArchiver: self.archiver,
            customChecksumAlgorithm: self.checksumAlgorithm,
            resolverUpdateEnabled: self.resolverUpdateEnabled,
            resolverPrefetchingEnabled: true,
            delegate: self.delegate
        )

        self._workspace = workspace

        return workspace
    }

    private var _workspace: Workspace?

    public func closeWorkspace() {
        self._workspace = nil
    }

    public func rootPaths(for packages: [String]) -> [AbsolutePath] {
        return packages.map { rootsDir.appending(RelativePath($0)) }
    }

    public func checkEdit(
        packageName: String,
        path: AbsolutePath? = nil,
        revision: Revision? = nil,
        checkoutBranch: String? = nil,
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let diagnostics = DiagnosticsEngine()
        diagnostics.wrap {
            let ws = try self.getOrCreateWorkspace()
            ws.edit(
                packageName: packageName,
                path: path,
                revision: revision,
                checkoutBranch: checkoutBranch,
                diagnostics: diagnostics
            )
        }
        result(diagnostics)
    }

    public func checkUnedit(
        packageName: String,
        roots: [String],
        forceRemove: Bool = false,
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let diagnostics = DiagnosticsEngine()
        let rootInput = PackageGraphRootInput(packages: rootPaths(for: roots))
        diagnostics.wrap {
            let ws = try self.getOrCreateWorkspace()
            try ws.unedit(packageName: packageName, forceRemove: forceRemove, root: rootInput, diagnostics: diagnostics)
        }
        result(diagnostics)
    }

    public func checkResolve(pkg: String, roots: [String], version: TSCUtility.Version, _ result: (DiagnosticsEngine) -> Void) {
        let diagnostics = DiagnosticsEngine()
        let rootInput = PackageGraphRootInput(packages: rootPaths(for: roots))
        diagnostics.wrap {
            let workspace = try self.getOrCreateWorkspace()
            try workspace.resolve(packageName: pkg, root: rootInput, version: version, branch: nil, revision: nil, diagnostics: diagnostics)
        }
        result(diagnostics)
    }

    public func checkClean(_ result: (DiagnosticsEngine) -> Void) {
        let diagnostics = DiagnosticsEngine()
        diagnostics.wrap {
            let workspace = try self.getOrCreateWorkspace()
            workspace.clean(with: diagnostics)
        }
        result(diagnostics)
    }

    public func checkReset(_ result: (DiagnosticsEngine) -> Void) {
        let diagnostics = DiagnosticsEngine()
        diagnostics.wrap {
            let workspace = try self.getOrCreateWorkspace()
            workspace.reset(with: diagnostics)
        }
        result(diagnostics)
    }

    public func checkUpdate(
        roots: [String] = [],
        deps: [MockDependency] = [],
        packages: [String] = [],
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let diagnostics = DiagnosticsEngine()
        diagnostics.wrap {
            let dependencies = deps.map { $0.convert(baseURL: packagesDir, identityResolver: self.identityResolver) }
            let rootInput = PackageGraphRootInput(
                packages: rootPaths(for: roots), dependencies: dependencies
            )
            let workspace = try self.getOrCreateWorkspace()
            try workspace.updateDependencies(root: rootInput, packages: packages, diagnostics: diagnostics)
        }
        result(diagnostics)
    }

    public func checkUpdateDryRun(
        roots: [String] = [],
        deps: [MockDependency] = [],
        _ result: ([(PackageReference, Workspace.PackageStateChange)]?, DiagnosticsEngine) -> Void
    ) {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir, identityResolver: self.identityResolver) }
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        let diagnostics = DiagnosticsEngine()
        let changes = diagnostics.wrap { () -> [(PackageReference, Workspace.PackageStateChange)]? in
            let workspace = try self.getOrCreateWorkspace()
            return try workspace.updateDependencies(root: rootInput, diagnostics: diagnostics, dryRun: true)
        } ?? nil
        result(changes, diagnostics)
    }

    public func checkPackageGraph(
        roots: [String] = [],
        deps: [MockDependency],
        _ result: (PackageGraph, DiagnosticsEngine) -> Void
    ) {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir, identityResolver: self.identityResolver) }
        self.checkPackageGraph(roots: roots, dependencies: dependencies, result)
    }

    public func checkPackageGraph(
        roots: [String] = [],
        dependencies: [PackageDependency] = [],
        forceResolvedVersions: Bool = false,
        _ result: (PackageGraph, DiagnosticsEngine) -> Void
    ) {
        let diagnostics = DiagnosticsEngine()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        do {
            let workspace = try self.getOrCreateWorkspace()
            let graph = try workspace.loadPackageGraph(
                rootInput: rootInput, forceResolvedVersions: forceResolvedVersions, diagnostics: diagnostics
            )
            result(graph, diagnostics)
        } catch {
            preconditionFailure("expected graph to load, but failed with: \(error)\n\(diagnostics)")
        }
    }

    public func checkPackageGraphFailure(
        roots: [String] = [],
        deps: [MockDependency],
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir, identityResolver: self.identityResolver) }
        self.checkPackageGraphFailure(roots: roots, dependencies: dependencies, result)
    }

    public func checkPackageGraphFailure(
        roots: [String] = [],
        dependencies: [PackageDependency] = [],
        forceResolvedVersions: Bool = false,
        _ result: (DiagnosticsEngine) -> Void
    ) {
        let diagnostics = DiagnosticsEngine()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        _ = diagnostics.wrap {
            let workspace = try self.getOrCreateWorkspace()
            try workspace.loadPackageGraph(
                rootInput: rootInput, forceResolvedVersions: forceResolvedVersions, diagnostics: diagnostics
            )
        }
        result(diagnostics)
    }

    public struct ResolutionPrecomputationResult {
        public let result: Workspace.ResolutionPrecomputationResult
        public let diagnostics: DiagnosticsEngine
    }

    public func checkPrecomputeResolution(_ check: (ResolutionPrecomputationResult) -> Void) throws {
        let diagnostics = DiagnosticsEngine()
        let workspace = try self.getOrCreateWorkspace()
        let pinsStore = try workspace.pinsStore.load()

        let rootInput = PackageGraphRootInput(packages: rootPaths(for: roots.map { $0.name }), dependencies: [])
        let rootManifests = try temp_await { workspace.loadRootManifests(packages: rootInput.packages, diagnostics: diagnostics, completion: $0) }
        let root = PackageGraphRoot(input: rootInput, manifests: rootManifests)

        let dependencyManifests = try workspace.loadDependencyManifests(root: root, diagnostics: diagnostics)

        let result = try workspace.precomputeResolution(
            root: root,
            dependencyManifests: dependencyManifests,
            pinsStore: pinsStore,
            extraConstraints: []
        )

        check(ResolutionPrecomputationResult(result: result, diagnostics: diagnostics))
    }

    public func set(
        pins: [PackageReference: CheckoutState] = [:],
        managedDependencies: [ManagedDependency] = [],
        managedArtifacts: [ManagedArtifact] = []
    ) throws {
        let workspace = try self.getOrCreateWorkspace()
        let pinsStore = try workspace.pinsStore.load()

        for (ref, state) in pins {
            pinsStore.pin(packageRef: ref, state: state)
        }

        for dependency in managedDependencies {
            try self.fs.createDirectory(workspace.path(to: dependency), recursive: true)
            workspace.state.dependencies.add(dependency)
        }

        for artifact in managedArtifacts {
            try self.fs.createDirectory(artifact.path, recursive: true)

            workspace.state.artifacts.add(artifact)
        }

        try workspace.state.saveState()
    }

    public func resetState() throws {
        let workspace = try self.getOrCreateWorkspace()
        try workspace.resetState()
    }

    public enum State {
        public enum CheckoutState {
            case version(TSCUtility.Version)
            case revision(String)
            case branch(String)
        }

        case checkout(CheckoutState)
        case edited(AbsolutePath?)
        case local
    }

    public struct ManagedDependencyResult {
        public let managedDependencies: ManagedDependencies

        public init(_ managedDependencies: ManagedDependencies) {
            self.managedDependencies = managedDependencies
        }

        public func check(notPresent name: String, file: StaticString = #file, line: UInt = #line) {
            let dependency = self.managedDependencies[forNameOrIdentity: name]
            XCTAssert(dependency == nil, "Unexpectedly found \(name) in managed dependencies", file: file, line: line)
        }

        public func checkEmpty(file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(self.managedDependencies.count, 0, file: file, line: line)
        }

        public func check(dependency name: String, at state: State, file: StaticString = #file, line: UInt = #line) {
            guard let dependency = managedDependencies[forNameOrIdentity: name] else {
                XCTFail("\(name) does not exists", file: file, line: line)
                return
            }
            switch state {
            case .checkout(let checkoutState):
                switch checkoutState {
                case .version(let version):
                    XCTAssertEqual(dependency.checkoutState?.version, version, file: file, line: line)
                case .revision(let revision):
                    XCTAssertEqual(dependency.checkoutState?.revision.identifier, revision, file: file, line: line)
                case .branch(let branch):
                    XCTAssertEqual(dependency.checkoutState?.branch, branch, file: file, line: line)
                }
            case .edited(let path):
                if dependency.state != .edited(path) {
                    XCTFail("Expected edited dependency; found '\(dependency.state)' instead", file: file, line: line)
                }
            case .local:
                if dependency.state != .local {
                    XCTFail("Expected local dependency", file: file, line: line)
                }
            }
        }
    }

    public struct ManagedArtifactResult {
        public let managedArtifacts: ManagedArtifacts

        public init(_ managedArtifacts: ManagedArtifacts) {
            self.managedArtifacts = managedArtifacts
        }

        public func checkNotPresent(
            packageName: String,
            targetName: String,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            let artifact = self.managedArtifacts[packageName: packageName, targetName: targetName]
            XCTAssert(artifact == nil, "Unexpectedly found \(packageName).\(targetName) in managed artifacts", file: file, line: line)
        }

        public func checkEmpty(file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(self.managedArtifacts.count, 0, file: file, line: line)
        }

        public func check(
            packageName: String,
            targetName: String,
            source: ManagedArtifact.Source,
            path: AbsolutePath,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            guard let artifact = managedArtifacts[packageName: packageName, targetName: targetName] else {
                XCTFail("\(packageName).\(targetName) does not exists", file: file, line: line)
                return
            }
            XCTAssertEqual(artifact.path, path)
            switch (artifact.source, source) {
            case (.remote(let lhsURL, let lhsChecksum), .remote(let rhsURL, let rhsChecksum)):
                XCTAssertEqual(lhsURL, rhsURL, file: file, line: line)
                XCTAssertEqual(lhsChecksum, rhsChecksum, file: file, line: line)
            case (.local, .local):
                break
            default:
                XCTFail("wrong source type", file: file, line: line)
            }
        }
    }

    public func loadDependencyManifests(
        roots: [String] = [],
        deps: [MockDependency] = [],
        _ result: (Workspace.DependencyManifests, DiagnosticsEngine) -> Void
    ) throws {
        let dependencies = deps.map { $0.convert(baseURL: packagesDir, identityResolver: self.identityResolver) }
        let diagnostics = DiagnosticsEngine()
        let workspace = try self.getOrCreateWorkspace()
        let rootInput = PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies
        )
        let rootManifests = try tsc_await { workspace.loadRootManifests(packages: rootInput.packages, diagnostics: diagnostics, completion: $0) }
        let graphRoot = PackageGraphRoot(input: rootInput, manifests: rootManifests)
        let manifests = try workspace.loadDependencyManifests(root: graphRoot, diagnostics: diagnostics)
        result(manifests, diagnostics)
    }

    public func checkManagedDependencies(file: StaticString = #file, line: UInt = #line, _ result: (ManagedDependencyResult) throws -> Void) {
        do {
            let workspace = try self.getOrCreateWorkspace()
            try result(ManagedDependencyResult(workspace.state.dependencies))
        } catch {
            XCTFail("Failed with error \(error)", file: file, line: line)
        }
    }

    public func checkManagedArtifacts(file: StaticString = #file, line: UInt = #line, _ result: (ManagedArtifactResult) throws -> Void) {
        do {
            let workspace = try self.getOrCreateWorkspace()
            try result(ManagedArtifactResult(workspace.state.artifacts))
        } catch {
            XCTFail("Failed with error \(error)", file: file, line: line)
        }
    }

    public struct ResolvedResult {
        public let store: PinsStore

        public init(_ store: PinsStore) {
            self.store = store
        }

        public func check(notPresent name: String, file: StaticString = #file, line: UInt = #line) {
            XCTAssertFalse(self.store.pinsMap.keys.contains(where: { $0.description == name }), "Unexpectedly found \(name) in Package.resolved", file: file, line: line)
        }

        public func check(dependency package: String, at state: State, file: StaticString = #file, line: UInt = #line) {
            guard let pin = store.pinsMap.first(where: { $0.key.description == package })?.value else {
                XCTFail("Pin for \(package) not found", file: file, line: line)
                return
            }
            switch state {
            case .checkout(let state):
                switch state {
                case .version(let version):
                    XCTAssertEqual(pin.state.version, version, file: file, line: line)
                case .revision(let revision):
                    XCTAssertEqual(pin.state.revision.identifier, revision, file: file, line: line)
                case .branch(let branch):
                    XCTAssertEqual(pin.state.branch, branch, file: file, line: line)
                }
            case .edited, .local:
                XCTFail("Unimplemented", file: file, line: line)
            }
        }

        public func check(dependency package: String, url: String, file: StaticString = #file, line: UInt = #line) {
            guard let pin = store.pinsMap.first(where: { $0.key.description == package })?.value else {
                XCTFail("Pin for \(package) not found", file: file, line: line)
                return
            }

            XCTAssertEqual(pin.packageRef.location, url, file: file, line: line)
        }
    }

    public func checkResolved(file: StaticString = #file, line: UInt = #line, _ result: (ResolvedResult) throws -> Void) {
        do {
            let workspace = try self.getOrCreateWorkspace()
            try result(ResolvedResult(workspace.pinsStore.load()))
        } catch {
            XCTFail("Failed with error \(error)", file: file, line: line)
        }
    }
}

public final class MockWorkspaceDelegate: WorkspaceDelegate {
    private let lock = Lock()
    public var _events = [String]()

    public init() {}

    public func repositoryWillUpdate(_ repository: String) {
        self.append("updating repo: \(repository)")
    }

    public func repositoryDidUpdate(_ repository: String, duration: DispatchTimeInterval) {
        self.append("finished updating repo: \(repository)")
    }

    public func dependenciesUpToDate() {
        self.append("Everything is already up-to-date")
    }

    public func fetchingWillBegin(repository: String, fetchDetails: RepositoryManager.FetchDetails?) {
        self.append("fetching repo: \(repository)")
    }

    public func fetchingDidFinish(repository: String, fetchDetails: RepositoryManager.FetchDetails?, diagnostic: Diagnostic?, duration: DispatchTimeInterval) {
        self.append("finished fetching repo: \(repository)")
    }

    public func willCreateWorkingCopy(repository url: String, at path: AbsolutePath) {
        self.append("creating working copy for: \(url)")
    }

    public func didCreateWorkingCopy(repository url: String, at path: AbsolutePath, error: Diagnostic?) {
        self.append("finished creating working copy for: \(url)")
    }

    public func willCheckOut(repository url: String, revision: String, at path: AbsolutePath) {
        self.append("checking out repo: \(url)")
    }

    public func didCheckOut(repository url: String, revision: String, at path: AbsolutePath, error: Diagnostic?) {
        self.append("finsihed checking out repo: \(url)")
    }

    public func removing(repository: String) {
        self.append("removing repo: \(repository)")
    }

    public func willResolveDependencies(reason: WorkspaceResolveReason) {
        self.append("will resolve dependencies")
    }

    public func willLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind) {
        self.append("will load manifest for \(packageKind) package: \(url)")
    }

    public func didLoadManifest(packagePath: AbsolutePath, url: String, version: Version?, packageKind: PackageReference.Kind, manifest: Manifest?, diagnostics: [Diagnostic]) {
        self.append("did load manifest for \(packageKind) package: \(url)")
    }

    public func willComputeVersion(package: PackageIdentity, location: String) {
        // noop
    }

    public func didComputeVersion(package: PackageIdentity, location: String, version: String, duration: DispatchTimeInterval) {
        // noop
    }

    public func resolvedFileChanged() {
        // noop
    }

    public func downloadingBinaryArtifact(from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?) {
        // noop
    }

    public func didDownloadBinaryArtifacts() {
        // noop
    }

    private func append(_ event: String) {
        self.lock.withLock {
            self._events.append(event)
        }
    }

    public var events: [String] {
        self.lock.withLock {
            self._events
        }
    }

    public func clear() {
        self.lock.withLock {
            self._events = []
        }
    }
}

extension CheckoutState {
    public var version: Version? {
        get {
            switch self {
            case .revision:
                return .none
            case .version(let version, _):
                return version
            case .branch:
                return .none
            }
        }
    }

    public var branch: String? {
        get {
            switch self {
            case .revision:
                return .none
            case .version:
                return .none
            case .branch(let branch, _):
                return branch
            }
        }
    }
}

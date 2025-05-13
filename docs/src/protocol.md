# [**13.** Package and Storage Server Protocol Reference](@id Pkg-Server-Protocols)

The Julia Package Server Protocol (Pkg Protocol) and the Package Storage Server Protocol (Storage Protocol) define how Julia's package manager, Pkg, obtains and manages packages and their associated resources. They aim at enhancing the Julia package ecosystem, making it more efficient, reliable, and user-friendly, avoiding potential points of failure, and ensuring the permanent availability of package versions and artifacts which is paramount for the stability and reproducibility of Julia projects.

The Pkg client, by default, gets all resources over HTTPS from a single open source service run by the Julia community. This service for serving packages is additionally backed by multiple independent storage services which interface with proprietary origin services (GitHub, etc.) and guarantee persitent availabilty of resources into the future.

The protocols also aim to address some of the limitations that existed prior to its introduction.

- **Vanishing Resources.** It is possible for authors to delete code repositories of registered Julia packages. Without some kind of package server, no one can install a package which has been deleted. If someone happens to have a current fork of a deleted package, that can be made the new official repository for the package, but chances of them having no or outdated forks is high. An even worse situation could happen for artifacts since they tend not to be kept in version control and are much more likely to be served from "random" web servers at a fixed URL with content changing over time. Artifact publishers are unlikely to retain all past versions of artifacts, so old versions of packages that depend on specific artifact content will not be reproducible in the future unless we do something to ensure that they are kept around after the publisher has stopped hosting them. By storing all package versions and artifacts in a single place, we can ensure that they are available forever.
- **Usage Insights.** It is valuable for the Julia community to know how many people are using Julia or what the relative popularity of different packages and operating systems is. Julia uses GitHub to host it's ecosystem. GitHub - a commercial, proprietary service - has this information but does not make it available to the Julia community. We are of course using GitHub for free, so we can't complain, but it seems unfortunate that a commercial entity has this vauable information while the open source community remains in the dark. The Julia community really could use insight into who is using Julia and how, so that we can prioritize packages and platforms, and give real numbers when people ask "how many people are using Julia?"
- **Decoupling from Git and GitHub.** Prior to this, Julia package ecosystem was very deeply coupled to git and was even specialized on GitHub specifically in may ways. The Pkg and Storage Protocols allowed us to decouple ourselves from git as the primary mechanism for getting packages. Now Julia continues to support using git, but does not require it just to install packages from the default public registry anymore. This decoupling also paves the way for supporting other version control systems in the future, making git no longer so special. Special treatment of GitHub will also go away since we get the benefits of specializing for GitHub (fast tarball downloads) directly from the Pkg protocols.
- **Performance on the table.** Package installation got much faster since Julia 1.0, in large part because the new design allowed packages to be downloaded as tarballs, rather than requiring a git clone of the entire repository for each package. But we're still forced to download complete packages and artifacts when we update them, no matter how small the changes may be. What if we could get the best of both worlds? That is, download tarballs for installations and use tiny diffs for updates. This would massively accelerate package updates. This could be a game changer in certain cases. We could also do much better at serving resources to the world: since all our resources are immutable and content-addressed, global distribution and caching should be a breeze.
- **Firewall problems.** Prior to this, Pkg's need to connect to arbitrary servers using a miscellany of protocols caused several problems with firewalls. A large set of protocols and an unbounded list of servers needed to be whitelisted just to support default Pkg operation. If Pkg only needed to talk to a single service over a single, secure protocol (i.e. HTTPS), then whitelisting Pkg for standard use would be dead simple.

## Protocols & Services

1. **Pkg Protocol:** what Julia Pkg Clients speak to Pkg Servers. The Pkg Server serves all resources that Pkg Clients need to install and use registered packages, including registry data, packages and artifacts. It can send diffs to reduce the size of updates and bundles to reduce the number of requests that clients need to make to receive a set of updates. It is designed to be easily horizontally scalable and not to have any hard operational requirements: if service is slow, just start more servers; if a Pkg Server crashes, forget it and boot up a new one.  
2. **Storage Protocol:** what Pkg Servers speak to get resources from Storage Services. Julia clients do not interact with Storage services directly and multiple independent Storage Services can symmetrically (all are treated equally) provide their service to a given Pkg Server. Since Pkg Servers cache what they serve to Clients and handle convenient content presentation, Storage Services can expose a much simpler protocol: all they do is serve up complete versions of registries, packages and artifacts, while guaranteeing persistence and completeness. Persistence means: once a version of a resource has been served, that version can be served forever. Completeness means: if the service serves a registry, it can serve all package versions referenced by that registry; if it serves a package version, it can serve all artifacts used by that package.

Both protocols work over HTTPS, using only GET and HEAD requests. As is normal for HTTP, HEAD requests are used to get information about a resource, including whether it would be served, without actually downloading it. As described in what follows, the Pkg Protocol is client-to-server and may be unauthenticated, use basic auth, or OpenID; the Storage Protocol is server-to-server only and uses mutual authentication with TLS certificates.

The following diagram shows how these services interact with each other and with external services such as GitHub, GitLab and BitBucket for source control, and S3 and HDFS for long-term persistence:

                                            ┌───────────┐

                                            │ Amazon S3 │

                                            │  Storage  │

                                            └───────────┘

                                                  ▲

                                                  ║

                                                  ▼

                                  Storage   ╔═══════════╗       ┌───────────┐

                   Pkg            Protocol  ║  Storage  ║   ┌──▶│  GitHub   │

                 Protocol               ┌──▶║ Service A ║───┤   └───────────┘

    ┏━━━━━━━━━━━━┓     ┏━━━━━━━━━━━━┓   │   ╚═══════════╝   │   ┌───────────┐

    ┃ Pkg Client ┃────▶┃ Pkg Server ┃───┤   ╔═══════════╗   ├──▶│  GitLab   │

    ┗━━━━━━━━━━━━┛     ┗━━━━━━━━━━━━┛   │   ║  Storage  ║   │   └───────────┘

                                        └──▶║ Service B ║───┤   ┌───────────┐

                                            ╚═══════════╝   └──▶│ BitBucket │

                                                  ▲             └───────────┘

                                                  ║

                                                  ▼

                                            ┌───────────┐

                                            │   HDFS    │

                                            │  Cluster  │

                                            └───────────┘

Each Julia Pkg Client is configured to talk to a Pkg Server. By default, they talk to `pkg.julialang.org`, a public, unauthenticated Pkg Server. If the environment variable `JULIA_PKG_SERVER` is set, the Pkg Client connects to that host instead. For example, if `JULIA_PKG_SERVER` is set to `pkg.company.com` then the Pkg Client will connect to `https://pkg.company.com`. So in typical operation, a Pkg Client will no longer rely on `libgit2` or a git command-line client, both of which have been an ongoing headache, especially behind firewalls and on Windows. If fact, git will only be necessary when working with git-hosted registries and unregistered packages - those will continue to work as they have previously, fetched using git.

While the default Pkg Server at `pkg.julialang.org` is unauthenticated, other parties may host Pkg Server instances elsewhere, authenticated or unauthenticated, public or private, as they wish. People can connect to those servers by setting the `JULIA_PKG_SERVER` variable. There will be a configuration file for providing authentication information to Pkg Servers using either basic auth or OpenID. The Pkg Server implementation will be open source and have minimal operational requirements. Specifically, it needs:

1. The ability to accept incoming connections on port 443;
2. The ability to connect to a configurable set of Storage Services;
3. Temporary disk storage for caching resources (registries, packages, artifacts).

A Pkg Service may be backed by more than one actual server, as is typical for web services. The Pkg Service is stateless, so this kind of horizontal scaling is straightforward. Each Pkg Server serves registry, package and artifact resources to Pkg Clients and caches whatever it serves. Each Pkg Server, in turn, gets those resources from one or more Storage Services. Storage services are responsible for fetching resources from code hosting sites like GitHub, GitLab and BitBucket, and for persisting everything that they have ever served to long-term storage systems like Amazon S3, a hosted HDFS clusters - or whatever an implementor wants to use. If the original copies of resources vanish, Pkg Servers must always serve up all previously served versions of resources.

The Storage Protocol is designed to be extremely simple so that multiple independent implementations can coexist, and each Pkg Server may be symmetrically backed by multiple different Storage Services, providing both redundant backup and ensuring that no single implementation has a "choke hold" on the ecosystem - anyone can implement a new Storage Service and add it to the set of services backing the default Pkg Server at `pkg.julialang.org`. The simplest possible version of a Storage Service is a static HTTPS site serving files generated from a snapshot of a registry. Although this does not provide adequate long-term backup capabilities, and would need to be regenerated whenever a registry changes, it may be sufficient for some private uses. Having multiple independently operated Storage Services helps ensure that even if one Storage Service become unavailable or unreliable - for technical, financial, or polictical reasons - others will keep operating and so will the Pkg ecosystem.

## The Pkg Protocol

This section descibes the protocol used by Pkg Clients to get resources from Pkg Servers, including the latest versions of registries, packages source trees, and artifacts. There is also a standard system for asking for diffs of all of these from previous versions, to minimize how much data the client needs to download in order to update itself. There is additionally a bundle mechanism for requesting and receiving a set of resources in a single request.

### Authentication

The authentication scheme between a Pkg client and server will be HTTP authorization with bearer tokens, as standardized in RFC6750. This means that authenticated access is accomplished by the client by making an HTTPS request including a `Authorization: Bearer $access_token` header.

The format of the token, its contents and validation mechanism are not specified by the Pkg Protocol. They are left to the server to define. The server is expected to validate the token and determine whether the client is authorized to access the requested resource. Similarly at the client side, the implementation of the token acquisition is not specified by the Pkg Protocol. However Pkg provides hooks that can be implemented at the client side to trigger the token acquisition process. Tokens thus acquired are expected to be stored in a local file, the format of which is specified by the Pkg Protocol. Pkg will be able to read the token from this file and include it in the request to the server. Pkg can also, optionally, detect when the token is about to expire and trigger a refresh. The Pkg client also supports automatic token refresh, since bearer tokens are recommended to be short-lived (no more than a day).

The authorization information is saved locally in `$(DEPOT_PATH[1])/servers/$server/auth.toml` which is a TOML file with the following fields:

- `access_token` (REQUIRED): the bearer token used to authorize normal requests
- `expires_at` (OPTIONAL): an absolute expiration time
- `expires_in` (OPTIONAL): a relative expiration time
- `refresh_token` (OPTIONAL): bearer token used to authorize refresh requests
- `refresh_url` (OPTIONAL): URL to fetch new a new token from

The `auth.toml` file may contain other fields (e.g. user name, user email), but they are ignored by Pkg. The two other fields mentioned in RFC6750 are `token_type` and `scope`: these are omitted since only tokens of type `Bearer` are supported currently and the scope is always implicitly to provide access to Pkg protocol URLs. Pkg servers should, however, not send auth.toml files with `token_type` or `scope` fields, as these names may be used in the future, e.g. to support other kinds of tokens or to limit the scope of an authorization to a subset of Pkg protocol URLs.

Initially, the user or user agent (IDE) must acquire a `auth.toml` file and save it to the correct location. After that, Pkg will determine whether the access token needs to be refreshed by examining the `expires_at` and/or `exipres_in` fields of the auth file. The expiration time is the minimum of `expires_at` and `mtime(auth_file) + expires_in`. When the Pkg client downloads a new `auth.toml` file, if there is a relative `exipres_in` field, an absolute `exipres_at` value is computed based on the client's current clock time. This combination of policies allows expiration to work gracefully even in the presence of clock skew between the server and the client.

If the access token is expired and there are `refresh_token` and `refresh_url` fields in `auth.toml`, a new auth file is requested by making a request to `refresh_url` with an `Authorization: Bearer $refresh_token` header. Pkg will refuse to make a refresh request unless `refresh_url` is an HTTPS URL. Note that `refresh_url` need not be a URL on the Pkg server: token refresh can be handled by separate server. If the request is successful and the returned `auth.toml` file is a well-formed TOML file with at least an `access_token` field, it is saved to `$(DEPOT_PATH[1])/servers/$server/auth.toml`.

Checking for access token expiry and refreshing `auth.toml` is done before each Pkg client request to a Pkg server, and if the auth file is updated the new access token is used, so the token should in theory always be up to date. Practice is different from theory, of course, and if the Pkg server considers the access token expired, it may return an HTTP 401 Unauthorized response, and the Pkg client should attempt to refresh the auth token. If, after attempting to refresh the access token, the server still returns HTTP 401 Unauthorized, the Pkg client server will present the body of the error response to the user or user agent (IDE).

## Authentication Hooks
A mechanism to register a hook at the client is provided to allow the user agent to handle an auth failure. It can, for example, present a login page and take the user through the necessary authentication flow to get a new auth token and store it in `auth.toml`.

- A handler can also be registered using [`register_auth_error_handler`](@ref Pkg.PlatformEngines.register_auth_error_handler). It returns a function that can be called to deregister the handler.
- A handler can also be deregistered using [`deregister_auth_error_handler`](@ref Pkg.PlatformEngines.deregister_auth_error_handler).

Example:

```julia
# register a handler
dispose = Pkg.PlatformEngines.register_auth_error_handler((url, svr, err) -> begin
    PkgAuth.authenticate(svr*"/auth")
    return true, true
end)

# ... client code ...

# deregister the handler
dispose()
# or
Pkg.PlatformEngines.deregister_auth_error_handler(url, svr)
```

### Resources

The client can make GET or HEAD requests to the following resources:

- `/registries`: map of registry uuids at this server to their current tree hashes, each line of the response data is of the form `/registry/$uuid/$hash` representing a resource pointing to particular version of a registry
- `/registry/$uuid/$hash`: tarball of registry uuid at the given tree hash
- `/package/$uuid/$hash`: tarball of package uuid at the given tree hash
- `/artifact/$hash`: tarball of an artifact with the given tree hash

Only the `/registries` changes - all other resources can be cached forever and the server will indicate this with the appropriate HTTP headers.

### Diffs

It is often benefical for the client to download a diff from a previous version of the registry, a package or an artifact. The following URL schemas allow the client to request a diff from a older version of each of these kinds of resources:

- `/registry/$uuid/$hash-$old`
- `/package/$uuid/$hash-$old`
- `/artifact/$hash-$old`

As with individual resources, these diff URLs are permanently cacheable. When the client requests a diff, if the server cannot compute the diff or decides it is not worth using a diff, the server replies with an HTTP 307 Temporary Redirect to the absolute version. For example, this is the sequence of requests and responses for a registry where it's better to just send a full new registry than to send a diff:

1. client ➝ server: `GET /registry/$uuid/$hash-$old`
2. server ➝ client: `307 /registry/$uuid/$hash`
3. client ➝ server: `GET /registry/$uuid/$hash`
4. server ➝ client: `200` (sends full regsitry tarball)

Further evaluation is needed before a diff format is picked. Two likely options are [vcdiff](https://en.wikipedia.org/wiki/VCDIFF) (likely computed by [xdelta](http://xdelta.org/)) or [bsdiff](https://github.com/mendsley/bsdiff) applied to uncompressed resource tarballs; the diff itself will then be compressed. The vcdiff format is standardized and fast to both compute and apply. The bsdiff format is not standardized, but is widely used and gets substantially better compression, especially of binaries, but is more computationally challenging to compute.

### Bundles

We can speed up batch operations by having the client request a bundle of resources at the same time. The bundle feature allows this using the following scheme:

- `/bundle/$hash`: a tarball of all the things you need to instantiate a manifest

When a GET request is made to `/bundle/$hash` the body of the GET request is a sorted, unique list of the resources that the client wants to receive. The hash value is a hash of this list. (If the body is not sorted, not unique, or if any of the items is invalid then the server response should be an error.) Although it is unusual for HTTP GET requests to have a body, it's not a violation of the standard (in spirit or in letter) as long as the same resource URL always gets the same response, which is guaranteed by the fact that the URL is determined by hashing the request body. As with resources and diffs, bundle URLs are permanently cacheable.

The list of resources in a bundle request can include diffs as well as full items. If the server would respond with a 307 redirect for any of the diffs requested, then it will respond with a 307 request for the entire bundle request, where the redirect response body contains the set of resources that the client should request instead and the resource name is the hash of that replacement resource list. The client then requests and uses the replacement bundle instead.

The body of a 200 response to a bundle request is a single tarball containing all of the requested resources with paths within the tarball corresponding to resource paths. For full resources, the directory at the location of that resource can be moved into the right place after the tarball is unpacked. For diff resources, the uncompressed diff of the resource will be at the resource location and can be applied to the old resource.

If the set of resources that a client requests is deemed too large by the server, it may respond with a "413 Payload Too Large" status code and the client should split the request into individual get requests or smaller bundle requests.

### Incremental Implementation

There is a straightforward approach to incrementally adding functionality to the Pkg Server protocol: first implement direct resource serving, then diffs and/or bundles independently. As long as the server speaks at least as recent a version of the protocol as the client, everything will work smoothly. Thus, if someone is running a Pkg Service, they must ensure that they have upgraded their service before any of the users of the service have upgraded their clients.

A reference implementation of the Pkg Server protocol is available at [PkgServer.jl](https://github.com/JuliaPackaging/PkgServer.jl).

## The Storage Protocol

This section descibes the protocol used by Pkg Servers to get resources from Storage Servers, including the latest versions of registries, packages source trees, and artifacts. Unlike in the Pkg Protocol, there is no support for diffs or bundles. The Pkg Server requests each type of resource when it needs it and caches it for as long as it can, so Storage Services should not have to serve the same resources to the same Pkg Server instance many times.

### Authentication

Since the Storage protocol is a server-to-server protocol, it uses certificate-based mutual authentication: each side of the connection presents certificates of identity to the other. The operator of a Storage Service must issue a client certificate to the operator of a Pkg Service certifying that it is authorized to use the Storage Service.

### Resources

The Storage Protocol is a simple sub-protocol of the Pkg Protocol, limited to only requesting the list of current registry hashes and full resource tarballs:

- `/registries`: map of registry uuids at this server to their current tree hashes
- `/registry/$uuid/$hash`: tarball of registry uuid at the given tree hash
- `/package/$uuid/$hash`: tarball of package uuid at the given tree hash
- `/artifact/$hash`: tarball of an artifact with the given tree hash

As is the case with the Pkg Server protocol, only the `/registries` resource changes over time—all other resources are permanently cacheable and Pkg Servers are expected to cache resources indefinitely, only deleting them if they need to reclaim storage space.

### Interaction

Fetching resources from a single Storage Server is straightforward: the Pkg Server asks for a version of a registry by UUID and hash and the Storage Server returns a tarball of that registry tree if it knows about that registry and version, or an HTTP 404 error if it doesn't.

Each Pkg Server may use multiple Storage Services for availability and depth of backup. For a given resource, the Pkg Server makes a HEAD request to each Storage Service requesting the resource, and then makes a GET request for the resource to the first Storage Server that replies to the HEAD request with a 200 OK. If no Storage Service responds with a 200 OK in enough time, the Pkg Server should respond to the request for the corresponding resource with a 404 error. Each Storage Service which responds with a 200 OK must behave as if it had served the resource, regardless of whether it does so or not - i.e. persist the resource to long-term storage.

One subtlety is how the Pkg Server determines what the latest version of each registry is. It can get a map from regsitry UUIDs to version hashes from each Storage Server, but hashes are unordered - if multiple Storage Servers reply with different hashes, which one should the Pkg Server use? When Storage Servers disagree on the latest hash of a registry, the Pkg Server should ask each Storage Server about the hashes that the other servers returned: if Service A knows about Service B's hash but B doesn't know about A's hash, then A's hash is more recent and should be used. If each server doesn't know about the other's hash, then neither hash is strictly newer than the other one and either could be used. The Pkg Server can break the tie any way it wants, e.g. randomly or by using the lexicographically earlier hash.

### Guarantees

The primary guarantee that a Storage Server makes is that if it has ever successfully served a resource—registry tree, package source tree, artifact tree — it must be able to serve that same resource version forever.

It's tempting to also require it to guarantee that if a Storage Server serves a registry tree, it can also serve every package source tree referred to within that registry tree. Similarly, it is tempting to require that if a Storage Server can serve a package source tree that it should be able to serve any artifacts referenced by that version of the package. However, this could fail for reasons entirely beyond the control of the server: what if the registry is published with wrong package hashes? What if someone registers a package version, doesn't git tag it, then force pushes the branch that the version was on? In both of these cases, the Storage Server may not be able to fetch a version of a package through no fault of its own. Similarly, artifact hashes in packages might be incorrect or vanish before the Storage Server can retrieve them.

Therefore, we don't strictly require that Storage Servers guarantee this kind of closure under resource references. We do, however, recommend that Storage Servers proactively fetch resources referred to by other resources as soon as possible. When a new version of a registry is available, the Storage Server should fetch all the new package versions in the registry immediately. When a package version is fetched—for any reason, whether because it was included in a new registry snapshot or because an upstream Pkg Server requested it by hash—all artifacts that it references should be fetched immediately.

## Verification

Since all resources are content addressed, the Pkg Clients and Pkg Server can and should verify that resource that it recieves from upstream have the correct content hash. If a resource does not have the right hash, it should not be used and not be served further downstream. Pkg Servers should try to fetch the resource from other Storage Services and serve one that has the correct content. Pkg Clients should error if they get a resource with an incorrect content hash.

Git uses SHA1 for content hashing. There is a pure Julia implementation of git's content hashing algorithm, which is being used to verify artifacts in Julia 1.3 (among other things). The SHA1 hashing algorithm is considered to be cryptographically compromised at this point, and while it's not completely broken, git is already starting to plan how to move away from using SHA1 hashes. To that end, we should consider getting ahead of this problem by using a stronger hash like SHA3-256 in these protocols. Having control over these protocols actually makes this considerably easier than if we were continuing to rely on git for resource acquisition.

The first step to using SHA3-256 instead of SHA1 is to populate registries with additional hashes for package versions. Currently each package version is identified by a git-tree-sha1 entry. We would add git-tree-sha3-256 entries that give the SHA3-256 hashes computed using the same git tree hashing logic. From this origin, the Pkg Client, Pkg Server and Storage Servers all just need to use SHA3-256 hashes rather than SHA1 hashes.

## References

1. Pkg & Storage Protocols [https://github.com/JuliaLang/Pkg.jl/issues/1377](https://github.com/JuliaLang/Pkg.jl/issues/1377)
2. Authenticated Pkg Client Support: [https://github.com/JuliaLang/Pkg.jl/pull/1538](https://github.com/JuliaLang/Pkg.jl/pull/1538)
3. Authentication Hooks: [https://github.com/JuliaLang/Pkg.jl/pull/1630](https://github.com/JuliaLang/Pkg.jl/pull/1630)

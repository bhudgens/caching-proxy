#! /usr/bin/env node_modules/.bin/coffee
Promise       = require 'bluebird'
using         = Promise.using
http          = require 'http'
httpProxy     = require 'http-proxy'
EventEmitter  = require 'events'
log           = require 'simplog'
crypto        = require 'crypto'
mocks         = require 'node-mocks-http'

config        = require './lib/config.coffee'
cache         = require './lib/cache.coffee'
admin         = require './lib/admin_handlers.coffee'
buildContext  = require './lib/context.coffee'
 
proxy = httpProxy.createProxyServer({ws: true})

# this event is raised when we get a response from the proxied service
# it is here that we will cache responses, while it'd be awesome to do this
# another way this is currently the only way to get the response from
# http-proxy
proxy.on 'proxyRes', (proxyRes, request, res) ->
  log.debug "proxy response received for key: %s contextId %s", request.cacheKey, request.contextId
  # a configuration may specify that the response be cached, or simply proxied.
  # In the case of caching being desired a cacheKey will be present otherwise
  # there will be no cacheKey.  So, if no cache key, no caching has been requested
  #
  if request.cacheKey
    cache.cacheResponse(request.cacheKey, proxyRes)

class RequestHandlingComplete extends Error
  constructor: (@stepOrMessage="") ->
    @requestHandlingComplete = true
    super()

noteStartTime = (context) ->
  context.requestStartTime = new Date()
  return context

setDebugIfAskedFor = (context) ->
  log.debug "setDebugIfAskedFor"
  return context unless context.isDebugRequest
  context.originalDebugValue = process.env.DEBUG
  log.debug "isDebugRequest: #{context.isDebugRequest}"
  process.env.DEBUG = true
  return context

determineIfAdminRequest = (context) ->
  log.debug "determineIfAdminRequest"
  adminRequestInfo = admin.getAdminRequestInfo(context.request)
  if adminRequestInfo
    context.isAdminRequest = true
    context.adminCommand = adminRequestInfo[0]
    context.url = adminRequestInfo[1]
    [context.pathOnly, context.queryString] = context.url.split('?')
    log.debug "we have an admin request command '%s' and url '%s'", context.adminCommand, context.url
  return context

getTargetConfigForRequest = (context) ->
    log.debug "getTargetConfigForRequest"
    # it's prossible to specify a proxy target in the request, this is intended to 
    # be used for testing configuration changes prior to setting them 'in stone' via
    # the config file, if the header IS present and an error is encountered while
    # parsing it, we'll blow up
    headerConfig = context.request.headers['x-proxy-target-config']
    if headerConfig
      try
        context.targetConfig = JSON.parse(headerConfig)
      catch e
        throw new Error("error parsing target config from provided header: #{headerConfig}\n #{e.message}")
    # if there was no config in the header, then we'll go ahead and load the matching config
    if not context.targetConfig
      context.targetConfig = config.findMatchingTarget(context.url)
    log.debug "target config: %j", context.targetConfig
    return context

stripPathIfRequested = (context) ->
  return context if context.targetConfig.sendPathWithProxiedRequest
  log.debug "stripPathIfRequested"
  context.url = ""
  return context

determineIfProxiedOnlyOrCached = (context) ->
  log.debug "determineIfProxiedOnlyOrCached"
  # it's a proxy only request if the maxAgeInMilliseconds is < 1, UNLESS it's an admin request which
  # is never a proxy only request
  context.isProxyOnly = context.targetConfig.maxAgeInMilliseconds < 1 unless context.isAdminRequest
  return context

handleProxyOnlyRequest = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) unless context.isProxyOnly
    log.debug "handleProxyOnlyRequest"
    proxyError = (e) ->
      log.error "error during proxy only request"
      reject(e)
    context.response.once 'finish', () ->
      #This one is a bit odd, because if we proxy the request, we're done that's all there is to do
      reject new RequestHandlingComplete()
    proxy.web(context.request, context.response, { target: context.targetConfig.target, headers: context.targetConfig.headers}, proxyError)

readRequestBody = (context) ->
  new Promise (resolve, reject) ->
    # we don't need the body for proxy only requests, it will simply be forwarded to the target
    return resolve(context) if context.isProxyOnly
    log.debug "readRequestBody"
    context.requestBody = ""
    context.request.on 'data', (data) -> context.requestBody += data
    context.request.once 'end', () -> resolve(context)
    context.request.once 'error', reject

buildCacheKey = (context) ->
  if context.targetConfig.maxAgeInMilliseconds
    # if we have a maxAgeInMilliseconds and it is less than 1, there is no cache key needed
    return context if context.targetConfig?.maxAgeInMilliseconds < 1

  if context.targetConfig.dayRelativeExpirationTimeInMilliseconds
    # if we have a dayRelativeExpirationTimeInMilliseconds and it is less than 1, there is no cache key needed
    return context if context.targetConfig.dayRelativeExpirationTimeInMilliseconds < 1
    
  log.debug "buildCacheKey"
  # build a cache key
  cacheKeyData = "#{context.method}-#{context.pathOnly}-#{context.queryString or ''}-#{context.requestBody or ""}"
  log.debug "request cache key data: #{cacheKeyData}"
  context.cacheKey = crypto.createHash('md5').update(cacheKeyData).digest("hex")
  log.debug "request cache key: #{context.cacheKey}"
  return context

handleAdminRequest = (context) ->
  # no admin command means it's not an admin request
  return context if not context.adminCommand
  log.debug "handleAdminRequest"
  admin.requestHandler context
  # admin 'stuff' is all handled in the admin handler so we're done here
  throw new RequestHandlingComplete()

getCachedResponse = (context) ->
  # nothing to do if there is no cache key
  return context if not context.cacheKey
  log.debug "getCachedResponse"
  cache.tryGetCachedResponse(context.cacheKey)
  .then (cachedResponse) ->
    context.cachedResponse = cachedResponse
    
    return context

dumpCachedResponseIfStaleResponseIsNotAllowed = (context) ->
  # here's the deal, if we want a cached response to NEVER be served IF stale, the target config
  # will be configued with a truthy serveStaleCache, so in that case we'll just flat dump any
  # cached response we may have IF it is expired we do it here before we get the cache lock
  # because we will need to acquire that ( if no one else has it ) in this case, as we'll be rebuilding it
  if not context.targetConfig.serveStaleCache and context.cachedResponseIsExpired
    log.debug "cached response expired, and our config specifies no serving stale cache items"
    context.cachedResponse = undefined
    # and since we've just erased our cached response, we need to clear this
    context.cachedResponseIsExpired = false
  return context

getCacheLockIfNoCachedResponseExists = (context) ->
  return context if context.cachedResponse # we have a cached, response no need to lock anything
  log.debug "getCacheLockIfNoCachedResponseExists"
  cache.promiseToGetCacheLock(context.cacheKey)
  .then (lockDescriptor) ->
    context.cacheLockDescriptor = lockDescriptor
    return context

getAndCacheResponseIfNeeded = (context) ->
  new Promise (resolve, reject) ->
    # get and cache a response for the given request, if there is already 
    # a cached response there is nothing to do
    return resolve(context) if context.cachedResponse
    log.debug "getAndCacheResponseIfNeeded"
    reject new Error("need a cacheKey inorder to cache a response, none present") if not context.cacheKey
    responseCachedHandler = (e) ->
      log.debug "responseCacheHandler for contextId %d", context.contextId
      if e
        reject(e)
      else
        cache.tryGetCachedResponse(context.cacheKey)
        .then (cachedResponse) ->
          context.cachedResponse = cachedResponse
          resolve(context)
        .catch (e) ->
          log.debug "error %s contextId %d", context.contextId, e
          reject(e)
    # if we've arrived here it's because the cached response didn't exist so we know we'll want to wait for one
    cache.events.once "#{context.cacheKey}", responseCachedHandler
    # only if we get the cache lock will we rebuild, otherwise someone else is
    # already rebuilding the cache metching this request
    if context.cacheLockDescriptor
      log.debug "we got cache lock %s for %s, triggering rebuild %d", context.cacheLockDescriptor, context.cacheKey, context.contextId
      fauxProxyResponse = mocks.createResponse()
      handleProxyError = (e) ->
        log.error "error proxying cache rebuild request to %s\n%s", context.targetConfig, e
        reject(e)
      proxy.web(context, fauxProxyResponse, { target: context.targetConfig.target, headers: context.targetConfig.headers }, handleProxyError)
    else
      log.debug "didn't get the cache lock for %s, waiting for in progress rebuild contextId %d", context.cacheKey, context.contextId

determineIfCacheIsExpired = (context) ->
  log.debug "determineIfCacheIsExpired"
  cachedResponse = context.cachedResponse
  return context unless cachedResponse
  # we start with the assumption that the cached response is not expired, and we prove otherwise
  # this err's on the side of serving the cached response as, if we have a cached response, the
  # expectation is that it will be served
  context.cachedResponseIsExpired = false
  now = new Date()
  if context.targetConfig.dayRelativeExpirationTimeInMilliseconds
    context.startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    context.absoluteExpirationTime = context.startOfDay + context.targetConfig.dayRelativeExpirationTimeInMilliseconds
    absoluteTimeNowInMs = now.getTime() - context.startOfDay
    log.debug "absolute expiration time: %s, now %s", context.targetConfig.dayRelativeExpirationTimeInMilliseconds, absoluteTimeNowInMs
    # if NOW is more than the configured value of milliesconds past the start of the day
    # AND we've not already cached a response for today, then we'll consider the cache expired
    context.cachedResponseIsExpired = ((absoluteTimeNowInMs) > context.targetConfig.dayRelativeExpirationTimeInMilliseconds) and (cachedResponse.createTime < context.absoluteExpirationTime)
  else
    # if our cached response is older than is configured for the max age, then we'll
    # queue up a rebuild request BUT still serve the cached response
    log.debug "create time: %s, now %s, delta %s, maxAge: %s", cachedResponse.createTime, now, now - cachedResponse.createTime, context.targetConfig.maxAgeInMilliseconds
    context.cachedResponseIsExpired = now - cachedResponse.createTime > context.targetConfig.maxAgeInMilliseconds
  return context

getCacheLockIfCacheIsExpired = (context) ->
  new Promise (resolve, reject) ->
    return resolve(context) unless context.cachedResponseIsExpired # if it's not expired, we have nothing to do
    log.debug "getCacheLockIfCacheIsExpired"
    cache.promiseToGetCacheLock(context.cacheKey)
    .then (lockDescriptor) ->
      # tight timing can lead us here when we already have a lock descriptor, so we want to make sure we don't overwrite
      # an existing lock descriptor, because we can end up here with a null value for the lockDescriptor
      context.cacheLockDescriptor = context.cacheLockDescriptor || lockDescriptor
      if lockDescriptor
        log.debug "got cache lock #{context.cacheLockDescriptor} for expired cache item #{context.contextId}"
      resolve(context)
    .catch reject

serveCachedResponse = (context) ->
  log.debug "serveCachedResponse"
  cachedResponse = context.cachedResponse
  cachedResponse.headers['x-cached-by-route'] = context.targetConfig.route
  cachedResponse.headers['x-cache-key'] = context.cacheKey
  cachedResponse.headers['x-cache-created'] = cachedResponse.createTime
  serveDuration = new Date().getTime() -  context.requestStartTime.getTime()
  cachedResponse.headers['x-cache-serve-duration-ms'] = serveDuration
  context.response.writeHead cachedResponse.statusCode, cachedResponse.headers
  cachedResponse.body.pipe(context.response)
  context.response.once 'finish', () -> log.info "%s cached response served in %d ms", context.request.url, serveDuration
  return context

triggerRebuildOfExpiredCachedResponse = (context) ->
  new Promise (resolve, reject) ->
    return reject new Error("no cached response found, cannot trigger rebuild") unless context.cachedResponse
    cachedResponse = context.cachedResponse
    if context.cachedResponseIsExpired and context.cacheLockDescriptor
      log.debug "triggerRebuildOfExpiredCachedResponse(%s)", context.cacheKey
      fauxProxyResponse = mocks.createResponse()
      handleProxyError = (e) ->
        log.error "error proxying cache rebuild request to %s\n%s", context.targetConfig.target, e
        reject(e)
      # while we don't actually need to wait for this response to be cached ( for the requestor ) because a
      # cached resopnse will have already been served, we do need to keep our pipeline going as expected
      # because we have a 'disposable' context that we use to manage this whole flow
      cache.events.once context.cacheKey, () -> resolve(context)
      return proxy.web(context, fauxProxyResponse, { target: context.targetConfig.target, headers: context.targetConfig.headers}, handleProxyError)
    resolve(context)

resetDebugIfAskedFor = (context) ->
  log.debug "resetDebugIfAskedFor"
  return context unless context.isDebugRequest
  process.env.DEBUG = context.originalDebugValue
  return context

server = http.createServer (request, response) ->
  log.debug "#{request.method} #{request.url}"
  getContextThatUnlocksCacheOnDispose = () ->
    buildContext(request, response).disposer (context, promise) ->
      log.debug "disposing of request %d", context.contextId
      if context.cacheLockDescriptor
        log.debug "unlocking cache lock %s during context dispose %d", context.cacheLockDescriptor, context.contextId
        cache.promiseToReleaseCacheLock(context.cacheLockDescriptor)
      else
        log.debug "cache not locked, no unlock needed during context dispose"

  requestPipeline = (context) ->
    Promise.resolve(context)
    .then noteStartTime
    .then setDebugIfAskedFor
    .then determineIfAdminRequest
    .then getTargetConfigForRequest
    .then stripPathIfRequested
    .then determineIfProxiedOnlyOrCached
    .then handleProxyOnlyRequest
    .then readRequestBody
    .then buildCacheKey
    .then handleAdminRequest
    .then getCachedResponse
    .then determineIfCacheIsExpired
    .then dumpCachedResponseIfStaleResponseIsNotAllowed
    .then getCacheLockIfNoCachedResponseExists
    .then getAndCacheResponseIfNeeded
    .then getCacheLockIfCacheIsExpired
    .then serveCachedResponse
    .then triggerRebuildOfExpiredCachedResponse
    .then resetDebugIfAskedFor
    .tap -> log.debug("request handling complete")
    .catch RequestHandlingComplete, (e) ->
      log.debug "request handling completed in catch"
    .catch (e) ->
      log.error "error processing request"
      log.error e.stack
      response.writeHead 500, {}
      response.end('{"status": "error", "message": "' + e.message + '"}')
  using(getContextThatUnlocksCacheOnDispose(), requestPipeline)

log.info "listening on port %s", config.listenPort
log.info "configuration: %j", config
log.debug "debug logging enabled"

proxyWebsocket = (context) ->
  proxy.ws(context.request, context.socket, context.head, { target: context.targetConfig.target, xfwd: true, headers: context.targetConfig.headers})
  return context
# websockets can be proxied, but they are not cached as that would be a whole giant ball of nasty
# however they are configued similarly to 'normal' HTTP targets
server.on 'upgrade', (request, socket, head) ->
  buildContext(request, null)
  .then (context) ->
    context.socket = socket
    context.head = head
    context
  .then getTargetConfigForRequest
  .then proxyWebsocket

server.listen(config.listenPort)

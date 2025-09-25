import 'dart:async';
import 'dart:collection';
import 'dart:io' show Stdout;

import 'package:console/console.dart';
import 'package:meta/meta.dart';

import 'destination.dart';
import 'link.dart';
import 'parsers/url_skipper.dart';
import 'server_info.dart';
import 'uri_glob.dart';
import 'worker/fetch_results.dart';
import 'worker/pool.dart';

/// Number of isolates to create by default.
const defaultThreads = 8;

/// Number of isolates to create when all we check are localhost sources.
const localhostOnlyThreads = 4;

/// Specifies where a URI (without fragment) can be found. Used by a hashmap
/// in [crawl].
enum Bin { open, openExternal, inProgress, closed }

Future<CrawlResult> crawl(
    List<Uri> seeds,
    Set<String> hostGlobs,
    bool shouldCheckExternal,
    UrlSkipper skipper,
    bool verbose,
    bool ansiTerm,
    Stream<dynamic> stopSignal,
    Stdout stdout) async {
  // Redirect output to injected [stdout] for better testing.
  void print(Object message) => stdout.writeln(message);

  Cursor? cursor;
  TextPen? pen;
  if (ansiTerm) {
    Console.init();
    cursor = Cursor();
    pen = TextPen();
  }

  if (verbose) {
    print('Crawl will start on the following URLs: $seeds');
    print('Crawl will check pages only on URLs satisfying: $hostGlobs');
    print('Crawl will skip links that match patterns: $skipper');
  }

  final uriGlobs = hostGlobs.map((glob) => UriGlob(glob)).toList();

  // Maps from URLs (without fragment) to where their corresponding destination
  // lives.
  final bin = <String, Bin>{};

  // The queue of destinations that haven't been tried yet. Destinations in
  // the front of the queue take precedence.
  final open = Queue<Destination>.from(seeds
      .map((uri) => Destination(uri)
        ..isSeed = true
        ..isSource = true
        ..isExternal = false)
      .toSet());
  for (final destination in open) {
    bin[destination.url] = Bin.open;
  }

  // Queue for the external destinations.
  final openExternal = Queue<Destination>();

  final inProgress = <Destination>{};

  // The set of destinations that have been tried.
  final closed = <Destination>{};

  // Servers we are connecting to.
  final servers = <String, ServerInfo>{};
  final unknownServers = Queue<String>();
  final serversInProgress = <String>{};
  seeds.map((uri) => uri.authority).toSet().forEach((String host) {
    servers[host] = ServerInfo(host);
    unknownServers.add(host);
  });

  if (verbose) {
    print('Crawl will check the following servers (and their robots.txt) '
        'first: $unknownServers');
  }

  // Crate the links Set.
  final links = <Link>{};

  int threads;
  if (shouldCheckExternal ||
      seeds.any(
          (seed) => seed.host != 'localhost' && seed.host != '127.0.0.1')) {
    threads = defaultThreads;
  } else {
    threads = localhostOnlyThreads;
  }
  if (verbose) print('Using $threads threads.');

  final pool = Pool(threads, hostGlobs);
  await pool.spawn();

  var count = 0;
  if (!verbose) {
    if (cursor != null) {
      cursor.write('Crawling: $count');
    } else {
      print('Crawling...');
    }
  }

  // TODO:
  // - --cache for creating a .linkcheck.cache file

  final allDone = Completer<void>();

  // Respond to Ctrl-C
  late final StreamSubscription<void> stopSignalSubscription;
  stopSignalSubscription = stopSignal.listen((dynamic _) async {
    if (pen != null) {
      pen
          .text('\n')
          .red()
          .text('Ctrl-C')
          .normal()
          .text(' Terminating crawl.')
          .print();
    } else {
      print('\nSIGINT: Terminating crawl');
    }
    await pool.close();
    allDone.complete();
    await stopSignalSubscription.cancel();
  });

  /// Creates new jobs and sends them to the Pool of Workers, if able.
  void sendNewJobs() {
    while (unknownServers.isNotEmpty && pool.anyIdle) {
      final host = unknownServers.removeFirst();
      pool.checkServer(host);
      serversInProgress.add(host);
      if (verbose) {
        print('Checking robots.txt and availability of server: $host');
      }
    }

    bool serverIsKnown(Destination destination) =>
        servers.keys.contains(destination.uri.authority);

    final availableDestinations =
        _zip(open.where(serverIsKnown), openExternal.where(serverIsKnown));

    // In order not to touch the underlying iterables, we keep track
    // of the destinations we want to remove.
    final destinationsToRemove = <Destination>[];

    for (final destination in availableDestinations) {
      if (pool.allBusy) break;

      destinationsToRemove.add(destination);

      final host = destination.uri.authority;
      final server = servers[host];
      if (server == null || server.hasNotConnected) {
        destination.didNotConnect = true;
        closed.add(destination);
        bin[destination.url] = Bin.closed;
        if (verbose) {
          print('Automatically failing $destination because server $host has '
              'failed before.');
        }
        continue;
      }

      final serverBouncer = server.bouncer;
      if (serverBouncer != null &&
          !serverBouncer.allows(destination.uri.path)) {
        destination.wasDeniedByRobotsTxt = true;
        closed.add(destination);
        bin[destination.url] = Bin.closed;
        if (verbose) {
          print('Skipping $destination because of robots.txt at $host.');
        }
        continue;
      }

      final delay = server.getThrottlingDuration();
      if (delay > ServerInfo.minimumDelay) {
        // Some other worker is already waiting with a checkPage request.
        // Let's try and see if we have more interesting options down the
        // iterable. Do not remove it.
        destinationsToRemove.remove(destination);
        continue;
      }

      final worker = pool.checkPage(destination, delay);
      server.markRequestStart(delay);
      if (verbose) {
        print('Added: $destination to $worker with '
            '${delay.inMilliseconds}ms delay');
      }
      inProgress.add(destination);
      bin[destination.url] = Bin.inProgress;
    }

    for (final destination in destinationsToRemove) {
      open.remove(destination);
      openExternal.remove(destination);
    }

    if (unknownServers.isEmpty &&
        open.isEmpty &&
        openExternal.isEmpty &&
        pool.allIdle) {
      allDone.complete();
      return;
    }
  }

  // Respond to new server info from Worker
  pool.serverCheckResults.listen((ServerInfoUpdate result) {
    serversInProgress.remove(result.host);
    servers
        .putIfAbsent(result.host, () => ServerInfo(result.host))
        .updateFromServerCheck(result);
    if (verbose) {
      print('Server check of ${result.host} complete.');
    }

    if (verbose) {
      count += 1;
      print('Server check for ${result.host} complete: '
          "${result.didNotConnect ? 'didn\'t connect' : 'connected'}, "
          "${result.robotsTxtContents.isEmpty ? 'no robots.txt' : 'robots.txt found'}.");
    } else {
      if (cursor != null) {
        cursor.moveLeft(count.toString().length);
        count += 1;
        cursor.write(count.toString());
      } else {
        count += 1;
      }
    }

    sendNewJobs();
  });

  // Respond to fetch results from a Worker
  pool.fetchResults.listen((FetchResults result) {
    assert(bin[result.checked.url] == Bin.inProgress);

    // Find the destination this result is referring to.
    final destinations = inProgress
        .where((dest) => dest.url == result.checked.url)
        .toList(growable: false);
    if (destinations.isEmpty) {
      if (verbose) {
        print("WARNING: Received result for a destination that isn't in "
            'the inProgress set: $result');
        final isInOpen =
            open.where((dest) => dest.url == result.checked.url).isNotEmpty;
        final isInOpenExternal = openExternal
            .where((dest) => dest.url == result.checked.url)
            .isNotEmpty;
        final isInClosed =
            closed.where((dest) => dest.url == result.checked.url).isNotEmpty;
        print('- the url is in open: $isInOpen; '
            'in open external: $isInOpenExternal, in closed: $isInClosed');
      }
      return;
    } else if (destinations.length > 1) {
      if (verbose) {
        print('WARNING: Received result for a url (${result.checked.url} '
            'that matches several objects in the inProgress set: '
            '$destinations');
      }
      return;
    }
    final checked = destinations.single;

    inProgress.remove(checked);
    checked.updateFromResult(result.checked);

    if (verbose) {
      count += 1;
      print('Done checking: $checked (${checked.statusDescription}) '
          '=> ${result.links.length} links');
      if (checked.isBroken) {
        print('- BROKEN');
      }
    } else {
      if (cursor != null) {
        cursor.moveLeft(count.toString().length);
        count += 1;
        cursor.write(count.toString());
      } else {
        count += 1;
      }
    }

    closed.add(checked);
    bin[checked.url] = Bin.closed;

    final newDestinations = <Destination>{};

    // Add links' destinations to [newDestinations] if they haven't been
    // seen before.
    for (final link in result.links) {
      // Mark links as skipped first.
      if (skipper.skips(link.destinationUrlWithFragment)) {
        link.wasSkipped = true;
        if (verbose) {
          print('- will not be checking: ${link.destination} - '
              '${skipper.explain(link.destinationUrlWithFragment)}');
        }
        continue;
      }

      if (bin[link.destination.url] == null) {
        // Completely new destination.
        assert(open.where((d) => d.url == link.destination.url).isEmpty);
        assert(
            openExternal.where((d) => d.url == link.destination.url).isEmpty);
        assert(inProgress.where((d) => d.url == link.destination.url).isEmpty);
        assert(closed.where((d) => d.url == link.destination.url).isEmpty);

        final alreadyOnCurrent = newDestinations.lookup(link.destination);
        if (alreadyOnCurrent != null) {
          if (verbose) {
            print('- destination: ${link.destination} already '
                'seen on this page');
          }
          continue;
        }

        if (verbose) {
          print('- completely new destination: ${link.destination}');
        }

        newDestinations.add(link.destination);
      }
    }

    links.addAll(result.links);

    for (final destination in newDestinations) {
      if (destination.isInvalid) {
        if (verbose) {
          print('Will not be checking: $destination - invalid url');
        }
        continue;
      }

      // Making sure this is set. The next (wasSkipped) section could
      // short-circuit this loop so we have to assign to isExternal here
      // while we have the chance.
      destination.isExternal =
          !uriGlobs.any((glob) => glob.matches(destination.uri));

      if (destination.isUnsupportedScheme) {
        // Don't check unsupported schemes (like mailto:).
        closed.add(destination);
        bin[destination.url] = Bin.closed;
        if (verbose) {
          print('Will not be checking: $destination - unsupported scheme');
        }
        continue;
      }

      // The URL is external and wasn't skipped. We'll find out whether to
      // check it according to the [shouldCheckExternal] option.
      if (destination.isExternal) {
        if (shouldCheckExternal) {
          openExternal.add(destination);
          bin[destination.url] = Bin.openExternal;
          continue;
        } else {
          // Don't check external destinations.
          closed.add(destination);
          bin[destination.url] = Bin.closed;
          if (verbose) {
            print('Will not be checking: $destination - external');
          }
          continue;
        }
      }

      if (destination.isSource) {
        open.addFirst(destination);
        bin[destination.url] = Bin.open;
      } else {
        open.addLast(destination);
        bin[destination.url] = Bin.open;
      }
    }

    // Do any destinations have different hosts? Add them to unknownServers.
    final newHosts = newDestinations
        .where((destination) => !destination.isInvalid)
        .where((destination) => !destination.isUnsupportedScheme)
        .where((destination) => shouldCheckExternal || !destination.isExternal)
        .map((destination) => destination.uri.authority)
        .where((String host) =>
            !unknownServers.contains(host) &&
            !serversInProgress.contains(host) &&
            !servers.keys.contains(host));
    unknownServers.addAll(newHosts);

    // Continue sending new jobs.
    sendNewJobs();
  });

  if (verbose) {
    pool.messages.listen((message) {
      print(message);
    });
  }

  // Start the crawl. First, check servers for robots.txt etc.
  sendNewJobs();

  // This will suspend until after everything is done (or user presses Ctrl-C).
  await allDone.future;

  if (verbose) {
    print('All jobs are done or user pressed Ctrl-C');
  }

  await stopSignalSubscription.cancel();

  if (verbose) {
    print('Deduping destinations');
  }

  // Fix links (dedupe destinations).
  final urlMap = {
    for (final destination in closed) destination.url: destination
  };
  for (final link in links) {
    final canonical = urlMap[link.destination.url];
    // Note: If it wasn't for the possibility to SIGINT the process, we could
    // assert there is exactly one Destination per URL. There might not be,
    // though.
    if (canonical != null) {
      link.destination = canonical;
    }
  }

  if (verbose) {
    print('Closing the isolate pool');
  }

  if (!pool.isShuttingDown) {
    await pool.close();
  }

  assert(open.isEmpty);
  assert(closed.every((destination) =>
      destination.wasTried ||
      destination.isUnsupportedScheme ||
      (destination.isExternal && !shouldCheckExternal) ||
      destination.isUnsupportedScheme ||
      destination.wasDeniedByRobotsTxt));

  if (verbose) {
    print('Broken links');
    links.where((link) => link.destination.isBroken).forEach(print);
  }

  return CrawlResult(links, closed);
}

@immutable
class CrawlResult {
  final Set<Link> links;
  final Set<Destination> destinations;

  const CrawlResult(this.links, this.destinations);
}

/// Zips two iterables of [Destination] into one.
///
/// Alternates between [a] and [b]. When one of the iterables is depleted,
/// the second iterable's remaining values will be yielded.
Iterable<Destination> _zip(
    Iterable<Destination> a, Iterable<Destination> b) sync* {
  final aIterator = a.iterator;
  final bIterator = b.iterator;

  while (true) {
    final aExists = aIterator.moveNext();
    final bExists = bIterator.moveNext();
    if (!aExists && !bExists) break;

    if (aExists) yield aIterator.current;
    if (bExists) yield bIterator.current;
  }
}

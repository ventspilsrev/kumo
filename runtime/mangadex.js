// Built-in MangaDex source for Kumo.
//
// Written for this app against the official MangaDex API
// (https://api.mangadex.org/docs). It is NOT the old Paperback 0.7 extension.
// It has the same shape as a Paperback 0.8 source so that it runs in the same
// sandboxed runtime as installed sources and can be tested on a PC:
//
//   node harness/run.js --file runtime/mangadex.js MangaDex berserk
//
// MangaDex rules this file follows:
//  - Identify the app honestly in the User-Agent. Browser-style user agents
//    are answered with a challenge page instead of data.
//  - Stay under the global limit of 5 requests per second (we use 4).
//  - Page images come from the "MangaDex@Home" server the API assigns.
(function (global) {
  'use strict';

  var API = 'https://api.mangadex.org';
  var COVERS = 'https://uploads.mangadex.org/covers';
  var SITE = 'https://mangadex.org';
  var USER_AGENT = 'Kumo/0.5 (iPad manga reader)';
  var LANGUAGE = 'en';
  var PAGE = 20;
  // Shown unless the reader picks ratings in the filters. "pornographic" is opt-in.
  var DEFAULT_RATINGS = ['safe', 'suggestive', 'erotica'];
  var ALL_RATINGS = ['safe', 'suggestive', 'erotica', 'pornographic'];

  var SORTS = [
    ['relevance', 'Best match'], ['followedCount', 'Most followed'], ['rating', 'Top rated'],
    ['latestUploadedChapter', 'Latest update'], ['createdAt', 'Newest'], ['title', 'Title A to Z']
  ];
  var DEMOGRAPHICS = [['shounen', 'Shounen'], ['shoujo', 'Shoujo'], ['seinen', 'Seinen'], ['josei', 'Josei']];
  var STATUSES = [['ongoing', 'Ongoing'], ['completed', 'Completed'], ['hiatus', 'On hiatus'], ['cancelled', 'Cancelled']];
  var RATINGS = [['safe', 'Safe'], ['suggestive', 'Suggestive'], ['erotica', 'Erotica'], ['pornographic', 'Adult (18+)']];
  var ORIGINS = [['ja', 'Japanese (manga)'], ['ko', 'Korean (manhwa)'], ['zh', 'Chinese (manhua)']];

  var HOME = [
    { id: 'popular_new', title: 'Popular new titles', order: 'followedCount', recentDays: 30 },
    { id: 'latest', title: 'Latest updates', order: 'latestUploadedChapter' },
    { id: 'followed', title: 'Most followed', order: 'followedCount' },
    { id: 'rated', title: 'Top rated', order: 'rating' },
    { id: 'new', title: 'Recently added', order: 'createdAt' }
  ];

  // ----------------------------------------------------------------- helpers

  function query(pairs) {
    return pairs.map(function (p) { return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]); }).join('&');
  }

  // MangaDex text fields are objects keyed by language.
  function localized(text) {
    if (!text) return '';
    if (text[LANGUAGE]) return text[LANGUAGE];
    if (text['ja-ro']) return text['ja-ro'];
    var keys = Object.keys(text);
    return keys.length ? text[keys[0]] : '';
  }

  function capitalize(word) {
    return word ? word.charAt(0).toUpperCase() + word.slice(1) : '';
  }

  function related(manga, type) {
    return (manga.relationships || []).filter(function (r) { return r.type === type; });
  }

  function coverUrl(manga, size) {
    var cover = related(manga, 'cover_art')[0];
    var file = cover && cover.attributes && cover.attributes.fileName;
    return file ? COVERS + '/' + manga.id + '/' + file + '.' + size + '.jpg' : '';
  }

  // API timestamps for filters must look like 2026-11-14T10:00:00 (no zone).
  function daysAgo(days) {
    return new Date(Date.now() - days * 86400000).toISOString().slice(0, 19);
  }

  function toPartial(manga) {
    var a = manga.attributes || {};
    return App.createPartialSourceManga({
      mangaId: manga.id,
      title: localized(a.title) || 'Untitled',
      image: coverUrl(manga, 256),
      subtitle: a.lastChapter ? 'Ch. ' + a.lastChapter : capitalize(a.status)
    });
  }

  // ------------------------------------------------------------------ source

  var MangaDexInfo = {
    version: '1.0.0',
    name: 'MangaDex',
    icon: 'icon.png',
    author: 'Kumo (built in)',
    authorWebsite: SITE,
    description: 'Built-in source that uses the official MangaDex API.',
    contentRating: 'MATURE',
    websiteBaseURL: SITE,
    sourceTags: [],
    intents: 1 | 4   // chapters + home page sections
  };

  class MangaDex {
    constructor() {
      this.tagList = null;
      this.requestManager = App.createRequestManager({
        requestsPerSecond: 4,
        requestTimeout: 20000,
        interceptor: {
          interceptRequest: async function (request) {
            var headers = {};
            for (var key in request.headers || {}) headers[key] = request.headers[key];
            headers['User-Agent'] = USER_AGENT;
            request.headers = headers;
            return request;
          },
          interceptResponse: async function (response) { return response; }
        }
      });
    }

    async api(path) {
      var response = await this.requestManager.schedule(App.createRequest({ url: API + path, method: 'GET' }), 1);
      if (response.status === 429) throw new Error('MangaDex is asking to slow down (too many requests). Wait a minute and try again.');
      if (response.status === 404) throw new Error('MangaDex could not find this title or chapter. It may have been removed.');
      if (response.status >= 500) throw new Error('MangaDex has a server problem (HTTP ' + response.status + '). Try again in a moment.');
      if (response.status !== 200) throw new Error('MangaDex answered HTTP ' + response.status + '.');
      var json;
      try {
        json = JSON.parse(response.data || '');
      } catch (error) {
        throw new Error('MangaDex sent something that is not data. Try again in a moment.');
      }
      if (json.result === 'error') {
        var detail = json.errors && json.errors[0] && (json.errors[0].detail || json.errors[0].title);
        throw new Error('MangaDex reported an error' + (detail ? ': ' + detail : '.'));
      }
      return json;
    }

    // One page of a manga listing. `extra` is a list of [key, value] pairs.
    async list(extra, offset, ratings) {
      var pairs = [['limit', PAGE], ['offset', offset || 0], ['includes[]', 'cover_art'],
        ['availableTranslatedLanguage[]', LANGUAGE], ['hasAvailableChapters', 'true']];
      (ratings || DEFAULT_RATINGS).forEach(function (r) { pairs.push(['contentRating[]', r]); });
      var json = await this.api('/manga?' + query(pairs.concat(extra)));
      var next = (offset || 0) + PAGE;
      // The API refuses offsets beyond 10000.
      var more = next < Math.min(json.total || 0, 10000);
      return App.createPagedResults({
        results: (json.data || []).map(toPartial),
        metadata: more ? { offset: next } : undefined
      });
    }

    homePairs(section) {
      var pairs = [['order[' + section.order + ']', 'desc']];
      if (section.recentDays) pairs.push(['createdAtSince', daysAgo(section.recentDays)]);
      return pairs;
    }

    async getHomePageSections(sectionCallback) {
      for (var i = 0; i < HOME.length; i++) {
        var section = HOME[i];
        var page = await this.list(this.homePairs(section), 0);
        sectionCallback(App.createHomeSection({
          id: section.id, title: section.title, type: 'singleRowNormal',
          containsMoreItems: true, items: page.results
        }));
      }
    }

    async getViewMoreItems(homepageSectionId, metadata) {
      var section = HOME.filter(function (s) { return s.id === homepageSectionId; })[0];
      if (!section) return App.createPagedResults({ results: [] });
      return this.list(this.homePairs(section), (metadata && metadata.offset) || 0);
    }

    // ---- filters

    async loadTags() {
      if (!this.tagList) {
        var json = await this.api('/manga/tag');
        this.tagList = (json.data || []).map(function (t) {
          return { id: t.id, name: localized(t.attributes.name), group: t.attributes.group };
        }).sort(function (a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; });
      }
      return this.tagList;
    }

    async getSearchTags() {
      var tags = await this.loadTags();
      function group(name) {
        return tags.filter(function (t) { return t.group === name; })
          .map(function (t) { return App.createTag({ id: 'tag:' + t.id, label: t.name }); });
      }
      function fixed(prefix, list) {
        return list.map(function (p) { return App.createTag({ id: prefix + ':' + p[0], label: p[1] }); });
      }
      return [
        App.createTagSection({ id: 'genre', label: 'Genres', tags: group('genre') }),
        App.createTagSection({ id: 'theme', label: 'Themes', tags: group('theme') }),
        App.createTagSection({ id: 'demographic', label: 'Audience', tags: fixed('demo', DEMOGRAPHICS) }),
        App.createTagSection({ id: 'format', label: 'Format', tags: group('format') }),
        App.createTagSection({ id: 'status', label: 'Status', tags: fixed('status', STATUSES) }),
        App.createTagSection({ id: 'origin', label: 'Original language', tags: fixed('lang', ORIGINS) }),
        App.createTagSection({ id: 'sort', label: 'Sort by (pick one)', tags: fixed('sort', SORTS) }),
        App.createTagSection({ id: 'rating', label: 'Content rating (default: all except 18+)', tags: fixed('rating', RATINGS) }),
        App.createTagSection({ id: 'content', label: 'Content warnings', tags: group('content') })
      ];
    }

    async supportsTagExclusion() {
      return true;
    }

    async getSearchResults(searchQuery, metadata) {
      var pairs = [];
      var title = (searchQuery.title || '').trim();
      if (title) pairs.push(['title', title]);

      var sort = null;
      var ratings = [];
      var includedCount = 0;
      (searchQuery.includedTags || []).forEach(function (tag) {
        var at = tag.id.indexOf(':');
        var kind = tag.id.slice(0, at);
        var value = tag.id.slice(at + 1);
        if (kind === 'tag') { pairs.push(['includedTags[]', value]); includedCount++; }
        else if (kind === 'sort') sort = value;
        else if (kind === 'demo') pairs.push(['publicationDemographic[]', value]);
        else if (kind === 'status') pairs.push(['status[]', value]);
        else if (kind === 'lang') pairs.push(['originalLanguage[]', value]);
        else if (kind === 'rating' && ALL_RATINGS.indexOf(value) >= 0) ratings.push(value);
      });
      var excludedCount = 0;
      (searchQuery.excludedTags || []).forEach(function (tag) {
        // Only real tags can be excluded; MangaDex has no "not this status" filter.
        if (tag.id.indexOf('tag:') === 0) { pairs.push(['excludedTags[]', tag.id.slice(4)]); excludedCount++; }
        else if (tag.id.indexOf('lang:') === 0) pairs.push(['excludedOriginalLanguage[]', tag.id.slice(5)]);
      });
      // A title must have ALL included tags and NONE of the excluded ones.
      if (includedCount) pairs.push(['includedTagsMode', 'AND']);
      if (excludedCount) pairs.push(['excludedTagsMode', 'OR']);

      if (!sort) sort = title ? 'relevance' : 'followedCount';
      pairs.push(['order[' + sort + ']', sort === 'title' ? 'asc' : 'desc']);

      return this.list(pairs, (metadata && metadata.offset) || 0, ratings.length ? ratings : null);
    }

    // ---- one title

    getMangaShareUrl(mangaId) {
      return SITE + '/title/' + mangaId;
    }

    async getMangaDetails(mangaId) {
      var json = await this.api('/manga/' + mangaId + '?' + query([
        ['includes[]', 'cover_art'], ['includes[]', 'author'], ['includes[]', 'artist']]));
      var manga = json.data;
      var a = manga.attributes || {};

      var titles = [localized(a.title) || 'Untitled'];
      (a.altTitles || []).forEach(function (alt) {
        if (alt[LANGUAGE] && titles.indexOf(alt[LANGUAGE]) < 0) titles.push(alt[LANGUAGE]);
      });
      function names(type) {
        return related(manga, type).map(function (r) { return r.attributes && r.attributes.name; })
          .filter(Boolean).filter(function (n, i, all) { return all.indexOf(n) === i; }).join(', ');
      }
      var sections = {};
      (a.tags || []).forEach(function (t) {
        var groupName = t.attributes.group;
        (sections[groupName] = sections[groupName] || []).push(
          App.createTag({ id: 'tag:' + t.id, label: localized(t.attributes.name) }));
      });
      var tagSections = ['genre', 'theme', 'format', 'content'].filter(function (g) { return sections[g]; })
        .map(function (g) { return App.createTagSection({ id: g, label: g === 'genre' ? 'Genres' : capitalize(g), tags: sections[g] }); });
      if (a.publicationDemographic) {
        tagSections.push(App.createTagSection({ id: 'demographic', label: 'Audience', tags: [
          App.createTag({ id: 'demo:' + a.publicationDemographic, label: capitalize(a.publicationDemographic) })] }));
      }

      return App.createSourceManga({
        id: mangaId,
        mangaInfo: App.createMangaInfo({
          titles: titles,
          image: coverUrl(manga, 512),
          status: capitalize(a.status),
          author: names('author'),
          artist: names('artist'),
          desc: localized(a.description),
          tags: tagSections,
          hentai: a.contentRating === 'pornographic'
        })
      });
    }

    async getChapters(mangaId) {
      var chapters = [];
      var seen = {};
      var offset = 0;
      var total = 1;
      // The feed returns at most 500 chapters per request.
      for (var round = 0; round < 20 && offset < total; round++) {
        var pairs = [['limit', 500], ['offset', offset], ['translatedLanguage[]', LANGUAGE],
          ['order[volume]', 'desc'], ['order[chapter]', 'desc'], ['includes[]', 'scanlation_group']];
        ALL_RATINGS.forEach(function (r) { pairs.push(['contentRating[]', r]); });
        var json = await this.api('/manga/' + mangaId + '/feed?' + query(pairs));
        total = json.total || 0;
        offset += 500;
        (json.data || []).forEach(function (chapter) {
          var a = chapter.attributes || {};
          // Skip chapters hosted on another site and empty ones: they cannot be read here.
          if (a.externalUrl || !a.pages) return;
          // Several groups often translate the same chapter. Keep one of each number.
          if (a.chapter != null) {
            var key = (a.volume || '') + '|' + a.chapter;
            if (seen[key]) return;
            seen[key] = true;
          }
          var group = related(chapter, 'scanlation_group')[0];
          var number = parseFloat(a.chapter);
          var volume = parseFloat(a.volume);
          var name = a.chapter != null ? 'Chapter ' + a.chapter : 'Oneshot';
          if (a.title) name += ': ' + a.title;
          chapters.push(App.createChapter({
            id: chapter.id,
            name: name,
            chapNum: isNaN(number) ? 0 : number,
            volume: isNaN(volume) ? 0 : volume,
            group: group && group.attributes ? group.attributes.name : '',
            time: new Date(a.publishAt || a.createdAt),
            langCode: LANGUAGE
          }));
        });
      }
      if (!chapters.length) {
        throw new Error('MangaDex has no readable English chapters for this title. It may only link to an official site.');
      }
      return chapters;
    }

    async getChapterDetails(mangaId, chapterId) {
      var json = await this.api('/at-home/server/' + chapterId);
      var chapter = json.chapter || {};
      var base = json.baseUrl + '/data/' + chapter.hash + '/';
      return App.createChapterDetails({
        id: chapterId,
        mangaId: mangaId,
        pages: (chapter.data || []).map(function (file) { return base + file; })
      });
    }
  }

  global.Sources = { MangaDex: MangaDex, MangaDexInfo: MangaDexInfo };
})(this);

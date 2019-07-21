use Pod::Load;
use Pod::Utilities;
use Pod::To::Cached;
use Pod::Utilities::Build;

use URI::Escape;
use Perl6::Utils;
use Perl6::TypeGraph;
use Perl6::Documentable;
use Perl6::Documentable::File;

use Perl6::Documentable::LogTimelineSchema;

unit class Perl6::Documentable::Registry;

has                  @.documentables;
has                  @.definitions;
has Bool             $.composed;
has                  %.cache;
has Perl6::TypeGraph $.tg;
has                  %.routines-by-type;

has Pod::To::Cached $.pod-cache;
has Bool            $.use-cache;

has Bool $.verbose;
has Str  $.topdir;

submethod BUILD (
    Str     :$topdir?    = "doc",
            :@dirs       = [],
    Bool    :$verbose?   = True,
    Bool    :$use-cache? = True,
) {
    $!verbose     = $verbose;
    $!use-cache   = $use-cache;
    $!tg          = Perl6::TypeGraph.new-from-file;
    $!topdir      = $topdir;

    # init cache if needed
    if ( $!use-cache ) {
        $!pod-cache = Pod::To::Cached.new(
            source => $!topdir,
            :$!verbose,
            path   => "." ~ $!topdir
        );
        $!pod-cache.update-cache;
    }

    # initialize the registry
    for @dirs -> $dir {
        self.process-pod-dir(:$dir).map(
            -> $doc {
            self.add-new( :$doc )
        });
    }
}

method add-new(Perl6::Documentable::File :$doc --> Perl6::Documentable::File) {
    die "Cannot add something to a composed registry" if $.composed;
    @!documentables.append: $doc;
    $doc;
}

method load (Str :$path --> Pod::Block::Named) {
    my $topdir = $!topdir;
    if ( $!use-cache ) {
        # topdir/dir/file.pod6 => dir/file
        my $new-path = $path.subst(/$topdir\//, "")
                       .subst(/\.pod6/, "").lc;
        return $!pod-cache.pod( $new-path ).first;
    } else {
        return load($path).first;
    }
}

method process-pod-dir(Str :$dir --> Array) {
    # pods to process
    my @pod-files = get-pod-names(:$!topdir, :$dir);

    for @pod-files.kv -> $num, (:key($filename), :value($file)) {
        Perl6::Documentable::LogTimeline::New.log: :$filename, -> {
            my $doc =Perl6::Documentable::File.new(
                dir      => $dir,
                pod      => self.load(path => $file.path),
                filename => $filename,
                tg       => $!tg
            );

            $doc.process;
            self.add-new: :$doc;
        }
    }
}
# consulting logic

method compose() {
    @!definitions = [$_.defs.Slip for @!documentables];

    %!routines-by-type = @!definitions.grep({.kind eq Kind::Routine})
                                      .classify({.origin.name});

    # compose types
    my @types = @!documentables.grep({.kind eq Kind::Type}).list;
    for @types -> $doc {
        self.compose-type($doc);
    }

    $!composed = True;
}

method lookup(Kind $what, Str :$by!) {
    unless %!cache{$by}:exists {
        for @!documentables.Slip, @!definitions.Slip -> $d {
            %!cache{$by}{$d."$by"()}.append: $d;
        }
    }
    %!cache{$by}{$what.gist} // [];
}

#| Completes a type pod with inherited routines
method compose-type($doc) {
    sub href_escape($ref) {
        # only valid for things preceded by a protocol, slash, or hash
        return uri_escape($ref).subst('%3A%3A', '::', :g);
    }

    my $pod     = $doc.pod;
    my $podname = $doc.name;
    my $type    = $!tg.types{$podname};

    {return;} unless $type;

    $pod.contents.append: self.typegraph-fragment($podname);

    my @roles-todo = $type.roles;
    my %roles-seen;
    while @roles-todo.shift -> $role {
        next unless %!routines-by-type{$role.name};
        next if %roles-seen{$role.name}++;
        @roles-todo.append: $role.roles;
        $pod.contents.append:
            pod-heading("Routines supplied by role $role"),
            pod-block(
                "$podname does role ",
                pod-link($role.name, "/type/{href_escape ~$role.name}"),
                ", which provides the following routines:",
            ),
            %!routines-by-type{$role.name}.list.map({.pod}),
        ;
    }

    for $type.mro.skip -> $class {
        if $type.name ne "Any" {
            next if $class.name ~~ "Any" | "Mu";
        }
        next unless %!routines-by-type{$class.name};
        $pod.contents.append:
            pod-heading("Routines supplied by class $class"),
            pod-block(
                "$podname inherits from class ",
                pod-link($class.name, "/type/{href_escape ~$class}"),
                ", which provides the following routines:",
            ),
            %!routines-by-type{$class.name}.list.map({.pod}),
        ;
        for $class.roles -> $role {
            next unless %!routines-by-type{$role.name};
            $pod.contents.append:
                pod-heading("Routines supplied by role $role"),
                pod-block(
                    "$podname inherits from class ",
                    pod-link($class.name, "/type/{href_escape ~$class}"),
                    ", which does role ",
                    pod-link($role.name, "/type/{href_escape ~$role}"),
                    ", which provides the following routines:",
                ),
                %!routines-by-type{$role.name}.list.map({.pod}),
            ;
        }
    }

}

#| Returns the fragment to show the typegraph image
method typegraph-fragment($podname is copy) {
    my $filename = "resources/template/tg-fragment.html".IO.e   ??
                   "resources/template/tg-fragment.html"        !!
                   %?RESOURCES<template/head.html>;
    state $template = slurp $filename;
    my $svg;
    if ("html/images/type-graph-$podname.svg".IO.e) {
        $svg = svg-for-file(
            zef-path("html/images/type-graph-$podname.svg")
        );
    } else {
        $svg = "<svg></svg>";
        $podname  = "404";
    }
    my $figure = $template.subst("PATH", $podname)
                          .subst("ESC_PATH", uri_escape($podname))
                          .subst("SVG", $svg);

    return [pod-heading("Type Graph"),
            Pod::Raw.new: :target<html>, contents => [$figure]]
}

# =================================================================================
# Indexing logic
# =================================================================================

method programs-index() {
    self.lookup(Kind::Programs, :by<kind>).map({%(
        name    => .name,
        url     => .url,
        summary => .summary
    )}).cache;
}

method language-index() {
    self.lookup(Kind::Language, :by<kind>).map({%(
        name    => .name,
        url     => .url,
        summary => .summary
    )}).cache;
}

method type-index() {
    [
        self.lookup(Kind::Type, :by<kind>)\
        .categorize(*.name).sort(*.key)>>.value
        .map({%(
            name     => .[0].name,
            url      => .[0].url,
            subkinds => .map({.subkinds // Nil}).flat.unique.List,
            summary  => .[0].summary,
            subkind  => .[0].subkinds[0]
        )}).cache.Slip
    ].flat.cache
}

method type-subindex(:$category) {
    self.lookup(Kind::Type, :by<kind>)\
    .grep({$category ⊆ .categories})\ # XXX
    .categorize(*.name).sort(*.key)>>.value
    .map({%(
        name     => .[0].name,
        url      => .[0].url,
        subkinds => .map({slip .subkinds // Nil}).unique.List,
        summary  => .[0].summary,
        subkind  => .[0].subkinds[0]
    )}).cache
}

method routine-index() {
    [
        self.lookup(Kind::Routine, :by<kind>)\
        .categorize(*.name).sort(*.key)>>.value
        .map({%(
            name     => .[0].name,
            url      => .[0].url,
            subkinds =>.map({.subkinds // Nil}).flat.unique.List,
            origins  => $_>>.origin.map({.name, .url}).List
        )}).cache.Slip
    ].flat.cache
}

method routine-subindex(:$category) {
    self.lookup(Kind::Routine, :by<kind>)\
    .grep({$category ⊆ .categories})\ # XXX
    .categorize(*.name).sort(*.key)>>.value
    .map({%(
        subkinds => .map({slip .subkinds // Nil}).unique.List,
        name     => .[0].name,
        url      => .[0].url,
        origins  => $_>>.origin.map({.name, .url}).List
    )})
}

# =================================================================================
# search index logic
# =================================================================================

method new-search-entry(Str :$category, Str :$value, Str :$url) {
    qq[[\{ category: "{$category}", value: "{$value}", url: "{$url}" \}\n]]
}

#! this function is a mess, it needs to be fixed
method generate-search-index() {
    my @items;
    for Kind::Type, Kind::Programs, Kind::Language, Kind::Syntax, Kind::Routine -> $kind {
        @items.append: self.lookup($kind, :by<kind>).categorize({.name}) #! use punycode here too
                      .pairs.sort({.key}).map: -> (:key($name), :value(@docs)) {
                          self.new-search-entry(
                              category => ( @docs > 1 ?? $kind.gist !! @docs.[0].subkinds[0] ).wordcase,
                              value    => $name,
                              url      => "#"
                          )
                      }
    }

    # Add p5to6 functions to JavaScript search index
    my %f;
    try {
        find-p5to6-functions(
            pod => load("doc/Language/5to6-perlfunc.pod6")[0],
            functions => %f
        );
        CATCH {return @items;}
    }

    @items.append: %f.keys.map( {
        my $url = "/language/5to6-perlfunc#" ~ $_.subst(' ', '_', :g);
        self.new-search-entry(
            category => "5to6-perlfunc",
            value    => $_,
            url      => $url
        )
    });

    return @items;
}
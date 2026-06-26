package Koha::Plugin::Com::LibTrack::LibraryTrack;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use C4::Context;
use Koha::Patrons;
use JSON qw(encode_json decode_json);
use Data::UUID;
use Try::Tiny;
use Carp;

## no critic (Variables::ProhibitPackageVars)
our $VERSION = '1.0.0';
our $metadata = {
    name            => 'LibraryTrack',
    author          => 'LibTrack',
    description     => 'Log reference interactions and capture Stories of Impact',
    date_authored   => '2026-06-24',
    date_updated    => '2026-06-24',
    minimum_version => '22.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    configure       => 0,
};
## use critic

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub metadata { return $metadata; }

sub install {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;

    $dbh->do(<<'SQL');
        CREATE TABLE IF NOT EXISTS `koha_plugin_libtrack_interactions` (
            `id`               VARCHAR(36)  NOT NULL,
            `type`             VARCHAR(255) NULL,
            `duration`         VARCHAR(255) NULL,
            `asked_by`         VARCHAR(255) NULL,
            `format`           VARCHAR(255) NULL,
            `location`         VARCHAR(255) NULL,
            `question`         TEXT         NULL,
            `answer`           TEXT         NULL,
            `tags`             TEXT         NULL,
            `initials`         VARCHAR(64)  NULL,
            `interaction_date` DATE         NULL,
            `interaction_time` VARCHAR(8)   NULL,
            `created_by`       INT          NULL,
            `created_at`       DATETIME     NOT NULL DEFAULT NOW(),
            PRIMARY KEY (`id`),
            KEY `idx_date` (`interaction_date`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

    $dbh->do(<<'SQL');
        CREATE TABLE IF NOT EXISTS `koha_plugin_libtrack_stories` (
            `id`          VARCHAR(36)  NOT NULL,
            `narrative`   TEXT         NULL,
            `outcome`     TEXT         NULL,
            `patron_type` VARCHAR(255) NULL,
            `program`     VARCHAR(255) NULL,
            `staff`       VARCHAR(255) NULL,
            `story_date`  DATE         NULL,
            `tags`        TEXT         NULL,
            `photo_url`   TEXT         NULL,
            `created_by`  INT          NULL,
            `created_at`  DATETIME     NOT NULL DEFAULT NOW(),
            PRIMARY KEY (`id`),
            KEY `idx_date` (`story_date`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

    # Field configuration (labels, dropdown options, promoted tags) is
    # stored as a single JSON blob under a fixed key.
    $dbh->do(<<'SQL');
        CREATE TABLE IF NOT EXISTS `koha_plugin_libtrack_config` (
            `config_key`   VARCHAR(64) NOT NULL,
            `config_value` LONGTEXT    NULL,
            PRIMARY KEY (`config_key`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;
    $self->install($args);
    # Photos are now plain URLs stored on the story row (the old chunked-photo
    # table is gone). Best-effort migration for installs created before this:
    # add the photo_url column and drop the obsolete photos table.
    my $dbh = C4::Context->dbh;
    
    my $alter_success = eval {
        $dbh->do('ALTER TABLE `koha_plugin_libtrack_stories` ADD COLUMN `photo_url` TEXT NULL');
        1;
    };
    carp "Failed to alter table during upgrade: $@" if !$alter_success;

    my $drop_success = eval { 
        $dbh->do('DROP TABLE IF EXISTS `koha_plugin_libtrack_photos`'); 
        1; 
    };
    carp "Failed to drop old photos table: $@" if !$drop_success;

    return 1;
}

sub uninstall {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_libtrack_interactions`');
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_libtrack_stories`');
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_libtrack_config`');
    return 1;
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};

    # Enforce global authentication check for all tool/asset/api routes
    my $env = C4::Context->userenv;
    unless ( $env && $env->{number} ) {
        print $cgi->header( -status => '401 Unauthorized', -type => 'text/plain' );
        print "Unauthorized";
        return 1;
    }

    # Route both the JSON API and the static bundle through method=tool so
    # they ride on the "Use tool plugins" permission rather than the
    # superlibrarian-only plugins.manage (which method=api / method=asset
    # require). Disambiguate by query param.
    if ( defined scalar $cgi->param('endpoint') ) {
        return $self->api($args);
    }
    if ( defined scalar $cgi->param('asset') ) {
        return $self->asset($args);
    }

    my $template = $self->get_template( { file => 'tool.tt' } );
    my $run_pl_base = '/cgi-bin/koha/plugins/run.pl?class=' . __PACKAGE__;
    my $api_base    = "$run_pl_base&method=tool";

    my $api_base_js_escaped = $api_base;
    $api_base_js_escaped =~ s{\\}{\\\\}gx;
    $api_base_js_escaped =~ s{"}{\\"}gx;
    my $api_base_js = qq{"$api_base_js_escaped"};

    $template->param(
        asset_base  => "$run_pl_base&method=tool&asset=1&v=$VERSION&file=",
        api_base    => $api_base,
        api_base_js => $api_base_js,
    );

    $self->output_html( $template->output() );
    return 1;
}

sub asset {
    my ( $self, $args ) = @_;
    my $cgi  = $self->{'cgi'};
    my $file = scalar $cgi->param('file') // '';

    # Security: Strict validation to prevent path traversal
    if ( $file !~ m{\A [\w\.\-]+ \z}x ) {
        print $cgi->header( -status => '400 Bad Request', -type => 'text/plain' );
        print "Invalid asset request";
        return;
    }

    my %types = (
        'index.js'    => 'application/javascript; charset=utf-8',
        'index.css'   => 'text/css; charset=utf-8',
        'favicon.svg' => 'image/svg+xml',
    );

    unless ( exists $types{$file} ) {
        print $cgi->header( -status => '404 Not Found', -type => 'text/plain' );
        print "Not found";
        return;
    }

    my $bundle = $self->bundle_path;
    my $path =
        $file =~ m{\.(js|css)\z}x
        ? "$bundle/htdocs/dist/assets/$file"
        : "$bundle/htdocs/dist/$file";

    unless ( -r $path ) {
        print $cgi->header( -status => '404 Not Found', -type => 'text/plain' );
        print "Asset missing on disk";
        return;
    }

    open my $fh, '<:raw', $path
      or do {
        print $cgi->header( -status => '500 Internal Server Error', -type => 'text/plain' );
        print "Read error";
        return;
      };
    my $content = do { local $/ = undef; <$fh> };
    close $fh;

    print $cgi->header(
        -type          => $types{$file},
        -cache_control => 'public, max-age=600, must-revalidate',
    );
    print $content;
    return;
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

sub _uuid { return lc( Data::UUID->new->create_str ); }

sub _patron_is_superlibrarian {
    my ($borrowernumber) = @_;
    return 0 unless $borrowernumber;
    my $patron = eval { Koha::Patrons->find($borrowernumber) };
    if ($@) {
        carp "Error finding patron: $@";
        return 0;
    }
    return 0 unless $patron;
    return $patron->is_superlibrarian ? 1 : 0;
}

sub _is_admin {
    my ($self) = @_;
    my $env = C4::Context->userenv;
    return 0 unless $env && $env->{number};
    return _patron_is_superlibrarian( $env->{number} );
}

sub _require_admin {
    my ($self) = @_;
    return 0 if $self->_is_admin;
    $self->_json_response( 403, {
        error => 'This action requires a Koha superlibrarian account.',
    });
    return 1;
}

sub _json_response {
    my ( $self, $status, $payload ) = @_;
    my $cgi = $self->{cgi};
    my %reason = (
        200 => 'OK', 201 => 'Created', 204 => 'No Content',
        400 => 'Bad Request', 401 => 'Unauthorized',
        403 => 'Forbidden', 404 => 'Not Found',
    );
    print $cgi->header(
        -status        => "$status " . ( $reason{$status} // 'Error' ),
        -type          => 'application/json',
        -charset       => 'UTF-8',
        -cache_control => 'no-store',
    );
    if ( $status != 204 && defined $payload ) {
        print encode_json($payload);
    }
    return;
}

# Decode the JSON body. Mutations are tunneled through GET with the body
# base64url-encoded in _body_b64 (standard base64 '/' becomes %2F, which
# Apache's default AllowEncodedSlashes Off rejects with a 404 before the
# plugin runs). Convert base64url back to standard base64 before decoding.
sub _read_body {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    my $b64 = scalar $cgi->param('_body_b64');
    if ( defined $b64 && length $b64 ) {
        require MIME::Base64;
        $b64 =~ tr{-_}{+/};
        my $decoded = eval { MIME::Base64::decode_base64($b64) };
        if ( defined $decoded && length $decoded ) {
            return eval { decode_json($decoded) };
        }
    }

    my $raw = $cgi->param('POSTDATA') // $cgi->param('PUTDATA') // '';
    if ( !$raw && $ENV{CONTENT_LENGTH} ) {
        local $/ = undef;
        read( STDIN, $raw, $ENV{CONTENT_LENGTH} );
    }
    return $raw ? eval { decode_json($raw) } : undef;
}

# JSON array <-> stored TEXT helpers for tags.
sub _encode_tags {
    my ($tags) = @_;
    $tags = [] unless ref $tags eq 'ARRAY';
    return encode_json($tags);
}

sub _decode_tags {
    my ($text) = @_;
    return [] unless defined $text && length $text;
    my $arr = eval { decode_json($text) };
    return ( ref $arr eq 'ARRAY' ) ? $arr : [];
}

sub _bool { 
    my ($val) = @_; 
    return $val ? \1 : \0; 
}

# ─── API ──────────────────────────────────────────────────────────────────────

sub api {
    my ( $self, $args ) = @_;
    my $cgi      = $self->{cgi};
    my $endpoint = scalar( $cgi->param('endpoint') ) // '';
    my $method   = uc( scalar( $cgi->param('_method') ) || $ENV{REQUEST_METHOD} || 'GET' );
    my $op       = scalar( $cgi->param('op') ) // '';

    try {
        my $dbh = C4::Context->dbh;

        my %dispatch = (
            me           => sub { return $self->_api_me() },
            config       => sub { return $self->_api_config( $dbh, $method ) },
            interactions => sub { return $self->_api_interactions( $dbh, $method, $op, $cgi ) },
            stories      => sub { return $self->_api_stories( $dbh, $method, $op, $cgi ) },
        );

        if ( exists $dispatch{$endpoint} ) {
            return $dispatch{$endpoint}->();
        }
        else {
            return $self->_json_response( 404, { error => "Unknown endpoint: '$endpoint'" } );
        }
    }
    catch {
        my $err = "$_";
        carp "LibraryTrack api error: $err";
        return $self->_json_response( 500, { error => $err } );
    };

    return 1;
}

sub _api_me {
    my ($self) = @_;
    my $env = C4::Context->userenv;
    unless ( $env && $env->{number} ) {
        return $self->_json_response( 401, { error => 'Not authenticated' } );
    }
    my $first = $env->{firstname} // '';
    my $sur   = $env->{surname}   // '';
    my $name  = $first ? "$first $sur" : $sur;
    my $initials = uc( substr( $first, 0, 1 ) . substr( $sur, 0, 1 ) );
    return $self->_json_response( 200, {
        id       => "" . $env->{number},
        name     => $name,
        initials => $initials,
        is_admin => _bool( _patron_is_superlibrarian( $env->{number} ) ),
    });
}

sub _api_config {
    my ( $self, $dbh, $method ) = @_;

    if ( $method eq 'GET' ) {
        my $row = $dbh->selectrow_arrayref(
            'SELECT config_value FROM koha_plugin_libtrack_config WHERE config_key = ?',
            undef, 'field_config',
        );
        if ( $row && defined $row->[0] ) {
            my $cfg = eval { decode_json( $row->[0] ) };
            return $self->_json_response( 200, $cfg ) if $cfg;
        }
        # No saved config yet — the frontend falls back to its defaults.
        return $self->_json_response( 200, undef );
    }

    # POST = save (superlibrarian only)
    return if $self->_require_admin;
    my $body = $self->_read_body;
    return $self->_json_response( 400, { error => 'Invalid config body' } )
        unless ref $body eq 'HASH';
    $dbh->do(<<'SQL', undef, 'field_config', encode_json($body));
        INSERT INTO koha_plugin_libtrack_config (config_key, config_value)
        VALUES (?, ?)
        ON DUPLICATE KEY UPDATE config_value = VALUES(config_value)
SQL
    return $self->_json_response( 200, $body );
}

sub _interaction_row_to_hash {
    my ($r) = @_;
    return {
        id               => $r->{id},
        type             => $r->{type}             // '',
        duration         => $r->{duration}         // '',
        asked_by         => $r->{asked_by}         // '',
        format           => $r->{format}           // '',
        location         => $r->{location}         // '',
        question         => $r->{question}         // '',
        answer           => $r->{answer}           // '',
        tags             => _decode_tags( $r->{tags} ),
        initials         => $r->{initials}         // '',
        interaction_date => $r->{interaction_date} // '',
        interaction_time => $r->{interaction_time} // '',
        created_at       => $r->{created_at}       // '',
    };
}

sub _api_interactions {
    my ( $self, $dbh, $method, $op, $cgi ) = @_;

    if ( $method eq 'GET' ) {
        my $rows = $dbh->selectall_arrayref(
            'SELECT * FROM koha_plugin_libtrack_interactions ORDER BY created_at DESC, id DESC',
            { Slice => {} },
        );
        return $self->_json_response( 200, [ map { _interaction_row_to_hash($_) } @$rows ] );
    }

    # All writes require an authenticated user (any logged-in staff may log).
    my $env = C4::Context->userenv;
    return $self->_json_response( 401, { error => 'Not authenticated' } )
        unless $env && $env->{number};

    if ( $op eq 'delete' ) {
        my $id = scalar $cgi->param('id');
        $dbh->do( 'DELETE FROM koha_plugin_libtrack_interactions WHERE id = ?', undef, $id );
        return $self->_json_response( 204, undef );
    }

    my $body = $self->_read_body;
    return $self->_json_response( 400, { error => 'Invalid body' } )
        unless ref $body eq 'HASH';

    if ( $op eq 'update' ) {
        my $id = scalar $cgi->param('id');
        $dbh->do(<<'SQL', undef, $body->{type}, $body->{duration}, $body->{asked_by}, $body->{format}, $body->{location}, $body->{question}, $body->{answer}, _encode_tags( $body->{tags} ), $body->{initials}, $body->{interaction_date}, $body->{interaction_time}, $id);
            UPDATE koha_plugin_libtrack_interactions SET
                type=?, duration=?, asked_by=?, format=?, location=?,
                question=?, answer=?, tags=?, initials=?,
                interaction_date=?, interaction_time=?
            WHERE id=?
SQL
        my $row = $dbh->selectrow_hashref(
            'SELECT * FROM koha_plugin_libtrack_interactions WHERE id = ?', undef, $id );
        # Idempotent: a stale/already-deleted id (or a replayed GET-tunneled
        # update) finds no row — return a no-op success instead of 500ing on an
        # undef dereference.
        return $self->_json_response( 204, undef ) unless $row;
        return $self->_json_response( 200, _interaction_row_to_hash($row) );
    }

    # Create
    my $id = _uuid();
    $dbh->do(<<'SQL', undef, $id, $body->{type}, $body->{duration}, $body->{asked_by}, $body->{format}, $body->{location}, $body->{question}, $body->{answer}, _encode_tags( $body->{tags} ), $body->{initials}, $body->{interaction_date}, $body->{interaction_time}, $env->{number});
        INSERT INTO koha_plugin_libtrack_interactions
            (id, type, duration, asked_by, format, location, question, answer,
             tags, initials, interaction_date, interaction_time, created_by)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
SQL
    my $row = $dbh->selectrow_hashref(
        'SELECT * FROM koha_plugin_libtrack_interactions WHERE id = ?', undef, $id );
    return $self->_json_response( 201, _interaction_row_to_hash($row) );
}

sub _story_row_to_hash {
    my ( $self, $dbh, $r ) = @_;
    return {
        id          => $r->{id},
        narrative   => $r->{narrative}   // '',
        outcome     => $r->{outcome}     // '',
        patron_type => $r->{patron_type} // '',
        program     => $r->{program}     // '',
        staff       => $r->{staff}       // '',
        story_date  => $r->{story_date}  // '',
        tags        => _decode_tags( $r->{tags} ),
        photo       => $r->{photo_url}   // '',
        created_at  => $r->{created_at}  // '',
    };
}

sub _api_stories {
    my ( $self, $dbh, $method, $op, $cgi ) = @_;

    if ( $method eq 'GET' ) {
        my $rows = $dbh->selectall_arrayref(
            'SELECT * FROM koha_plugin_libtrack_stories ORDER BY created_at DESC, id DESC',
            { Slice => {} },
        );
        return $self->_json_response( 200,
            [ map { $self->_story_row_to_hash( $dbh, $_ ) } @$rows ] );
    }

    my $env = C4::Context->userenv;
    return $self->_json_response( 401, { error => 'Not authenticated' } )
        unless $env && $env->{number};

    if ( $op eq 'delete' ) {
        my $id = scalar $cgi->param('id');
        $dbh->do( 'DELETE FROM koha_plugin_libtrack_stories WHERE id = ?', undef, $id );
        return $self->_json_response( 204, undef );
    }

    my $body = $self->_read_body;
    return $self->_json_response( 400, { error => 'Invalid body' } )
        unless ref $body eq 'HASH';

    if ( $op eq 'update' ) {
        my $id = scalar $cgi->param('id');
        # photo_url present in body means it changed: null/empty clears it.
        my $has_photo_change = exists $body->{photo_url};
        if ($has_photo_change) {
            $dbh->do(<<'SQL', undef, $body->{narrative}, $body->{outcome}, $body->{patron_type}, $body->{program}, $body->{staff}, $body->{story_date}, _encode_tags( $body->{tags} ), $body->{photo_url}, $id);
                UPDATE koha_plugin_libtrack_stories SET
                    narrative=?, outcome=?, patron_type=?, program=?, staff=?,
                    story_date=?, tags=?, photo_url=?
                WHERE id=?
SQL
        }
        else {
            $dbh->do(<<'SQL', undef, $body->{narrative}, $body->{outcome}, $body->{patron_type}, $body->{program}, $body->{staff}, $body->{story_date}, _encode_tags( $body->{tags} ), $id);
                UPDATE koha_plugin_libtrack_stories SET
                    narrative=?, outcome=?, patron_type=?, program=?, staff=?,
                    story_date=?, tags=?
                WHERE id=?
SQL
        }
        my $row = $dbh->selectrow_hashref(
            'SELECT * FROM koha_plugin_libtrack_stories WHERE id = ?', undef, $id );
        # Idempotent: a stale/already-deleted id (or a replayed GET-tunneled
        # update) finds no row — return a no-op success instead of 500ing on an
        # undef dereference.
        return $self->_json_response( 204, undef ) unless $row;
        return $self->_json_response( 200, $self->_story_row_to_hash( $dbh, $row ) );
    }

    # Create
    my $id = _uuid();
    $dbh->do(<<'SQL', undef, $id, $body->{narrative}, $body->{outcome}, $body->{patron_type}, $body->{program}, $body->{staff}, $body->{story_date}, _encode_tags( $body->{tags} ), $body->{photo_url}, $env->{number});
        INSERT INTO koha_plugin_libtrack_stories
            (id, narrative, outcome, patron_type, program, staff, story_date,
             tags, photo_url, created_by)
        VALUES (?,?,?,?,?,?,?,?,?,?)
SQL
    my $row = $dbh->selectrow_hashref(
        'SELECT * FROM koha_plugin_libtrack_stories WHERE id = ?', undef, $id );
    return $self->_json_response( 201, $self->_story_row_to_hash( $dbh, $row ) );
}

1;

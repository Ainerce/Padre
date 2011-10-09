package Padre::Wx::Syntax;

use 5.008;
use strict;
use warnings;
use Params::Util           ();
use Padre::Constant        ();
use Padre::Feature         ();
use Padre::Role::Task      ();
use Padre::Wx::Role::View  ();
use Padre::Wx              ();
use Padre::Wx::Icon        ();
use Padre::Wx::FBP::Syntax ();
use Time::HiRes            ();
use Padre::Logger;

our $VERSION = '0.91';
our @ISA     = qw{
	Padre::Role::Task
	Padre::Wx::Role::View
	Padre::Wx::FBP::Syntax
};

use constant {
	OK      => 'status/padre-syntax-ok',
	ERROR   => 'status/padre-syntax-error',
	WARNING => 'status/padre-syntax-warning',
};

# Load the bitmap icons for the label
my %ICON = (
	ok      => Padre::Wx::Icon::find(OK),
	error   => Padre::Wx::Icon::find(ERROR),
	warning => Padre::Wx::Icon::find(WARNING),
);

# perldiag error message classification
my %MESSAGE = (

	# (W) A warning (optional).
	'W' => {
		label  => Wx::gettext('Warning'),
		marker => Padre::Constant::MARKER_WARN,
	},

	# (D) A deprecation (enabled by default).
	'D' => {
		label  => Wx::gettext('Deprecation'),
		marker => Padre::Constant::MARKER_WARN,
	},

	# (S) A severe warning (enabled by default).
	'S' => {
		label  => Wx::gettext('Severe Warning'),
		marker => Padre::Constant::MARKER_WARN,
	},

	# (F) A fatal error (trappable).
	'F' => {
		label  => Wx::gettext('Fatal Error'),
		marker => Padre::Constant::MARKER_ERROR,
	},

	# (P) An internal error you should never see (trappable).
	'P' => {
		label  => Wx::gettext('Internal Error'),
		marker => Padre::Constant::MARKER_ERROR,
	},

	# (X) A very fatal error (nontrappable).
	'X' => {
		label  => Wx::gettext('Very Fatal Error'),
		marker => Padre::Constant::MARKER_ERROR,
	},

	# (A) An alien error message (not generated by Perl).
	'A' => {
		label  => Wx::gettext('Alien Error'),
		marker => Padre::Constant::MARKER_ERROR,
	},
);

sub new {
	my $class = shift;
	my $main  = shift;
	my $panel = shift || $main->bottom;
	my $self  = $class->SUPER::new($panel);

	# Hide the entries not visible by default
	$self->{help}->Hide;
	$self->{show_stderr}->Hide;

	# Additional properties
	$self->{model}       = {};
	$self->{annotations} = ();
	$self->{length}      = -1;

	# Prepare the available images
	my $images = Wx::ImageList->new( 16, 16 );
	$self->{images} = {
		ok          => $images->Add( Padre::Wx::Icon::icon(OK) ),
		error       => $images->Add( Padre::Wx::Icon::icon(ERROR) ),
		warning     => $images->Add( Padre::Wx::Icon::icon(WARNING) ),
		diagnostics => $images->Add(
			Wx::ArtProvider::GetBitmap(
				'wxART_GO_FORWARD',
				'wxART_OTHER_C',
				[ 16, 16 ],
			),
		),
		root => $images->Add(
			Wx::ArtProvider::GetBitmap(
				'wxART_HELP_FOLDER',
				'wxART_OTHER_C',
				[ 16, 16 ],
			),
		),
	};
	$self->{tree}->AssignImageList($images);

	$self->Hide;

	if (Padre::Feature::STYLE_GUI) {
		$self->main->style->apply( $self->{tree} );
	}

	return $self;
}





######################################################################
# Padre::Wx::Role::View Methods

sub view_panel {
	return 'bottom';
}

sub view_label {
	shift->gettext_label(@_);
}

sub view_close {
	$_[0]->main->show_syntaxcheck(0);
}

sub view_start {
	my $self = shift;
	my $lock = $self->lock_update;

	# Add the margins for the syntax markers
	foreach my $editor ( $self->main->editors ) {
		$editor->SetMarginWidth( 1, 16 );
	}
}

sub view_stop {
	my $self = shift;
	my $lock = $self->lock_update;

	# Clear out any state and tasks
	$self->task_reset;
	$self->clear;

	# Remove the editor margins
	foreach my $editor ( $self->main->editors ) {
		$editor->SetMarginWidth( 1, 0 );
	}

	return;
}





#####################################################################
# Event Handlers

sub on_tree_item_selection_changed {
	my $self  = shift;
	my $event = shift;
	my $item  = $event->GetItem or return;
	my $issue = $self->{tree}->GetPlData($item);

	if ( $issue and $issue->{diagnostics} ) {
		my $diag = $issue->{diagnostics};
		$self->_update_help_page($diag);
	} else {
		$self->_update_help_page;
	}
}

sub on_tree_item_activated {
	my $self   = shift;
	my $event  = shift;
	my $item   = $event->GetItem or return;
	my $issue  = $self->{tree}->GetPlData($item) or return;
	my $editor = $self->current->editor or return;
	my $line   = $issue->{line};

	# Does it point to somewhere valid?
	return unless defined $line;
	return if $line !~ /^\d+$/o;
	return if $editor->GetLineCount < $line;

	# Select the problem after the event has finished
	Wx::Event::EVT_IDLE(
		$self,
		sub {
			$self->select_next_problem( $line - 1 );
			Wx::Event::EVT_IDLE( $self, undef );
		},
	);
}

sub show_stderr {
	my $self   = shift;
	my $event  = shift;
	my $stderr = $self->{model}->{stderr};

	if ( defined $stderr ) {
		my $main = $self->main;
		$main->output->SetValue($stderr);
		$main->output->SetSelection( 0, 0 );
		$main->show_output(1);
	}
}





#####################################################################
# General Methods

sub gettext_label {
	Wx::gettext('Syntax Check');
}

# Remove all markers and empty the list
sub clear {
	my $self    = shift;
	my $lock    = $self->lock_update;
	my $feature = $self->config->feature_syntax_check_annotations;

	# Remove the margins and indicators for the syntax markers
	foreach my $editor ( $self->main->editors ) {
		$editor->MarkerDeleteAll(Padre::Constant::MARKER_ERROR);
		$editor->MarkerDeleteAll(Padre::Constant::MARKER_WARN);

		my $len = $editor->GetTextLength;
		if ( $len > 0 ) {

			# Clear out all indicators
			$editor->SetIndicatorCurrent(Padre::Constant::INDICATOR_WARNING);
			$editor->IndicatorClearRange( 0, $len );
			$editor->SetIndicatorCurrent(Padre::Constant::INDICATOR_ERROR);
			$editor->IndicatorClearRange( 0, $len );
		}

		# Clear all annotations if it is available and the feature is enabled
		$editor->AnnotationClearAll if $feature;
	}

	$self->{annotations} = () if $feature;

	# Remove all items from the tool
	$self->{tree}->DeleteAllItems;

	# Hide "Show Standard Error"
	$self->{show_stderr}->Hide;

	# Clear the help page
	$self->_update_help_page;

	return;
}

# Nothing to implement here
sub relocale {
	return;
}

sub refresh {
	my $self     = shift;
	my $current  = shift or return;
	my $document = $current->document;
	my $tree     = $self->{tree};
	my $lock     = $self->lock_update;

	# Abort any in-flight checks
	$self->task_reset;

	# Hide the widgets when no files are open
	unless ($document) {
		$self->clear;
		$tree->Hide;
		return;
	}

	# Is there a syntax check task for this document type
	my $task = $document->task_syntax;
	unless ($task) {
		$self->clear;
		$tree->Hide;
		return;
	}

	# Ensure the widget is visible
	$tree->Show(1);

	# Recalculate our layout in case the view geometry
	# has changed from when we were hidden.
	$self->Layout;

	# Clear out the syntax check window, leaving the margin as is
	$self->{tree}->DeleteAllItems;
	$self->_update_help_page;

	# Shortcut if there is nothing in the document to compile
	if ( $document->is_unused ) {
		return;
	}

	# Fire the background task discarding old results
	$self->{task_start_time} = Time::HiRes::time;
	$self->task_request(
		task     => $task,
		document => $document,
	);

	return 1;
}

sub task_finish {
	my $self = shift;
	my $task = shift;
	$self->{model} = $task->{model};

	# Properly validate and warn about older deprecated syntax models
	if ( Params::Util::_ARRAY0( $self->{model} ) ) {

		# Warn about the old array object from syntax task in debug mode
		TRACE(    q{Syntax checker tasks should now return a hash containing an 'issues' array reference}
				. q{ and 'stderr' string keys instead of the old issues array reference} )
			if DEBUG;

		# TODO remove compatibility for older syntax checker model
		if ( scalar @{ $self->{model} } == 0 ) {
			$self->{model} = {};
		} else {
			$self->{model} = {
				issues => $self->{model},
				stderr => undef,
			};
		}
	}

	$self->render;
}

sub render {
	my $self     = shift;
	my $elapsed  = Time::HiRes::time- $self->{task_start_time};
	my $model    = $self->{model} || {};
	my $current  = $self->current;
	my $editor   = $current->editor;
	my $document = $current->document;
	my $filename = $current->filename;
	my $lock     = $self->lock_update;
	my $feature  = $self->config->feature_syntax_check_annotations;

	if ($feature) {

		# Show only the current error/warning annotation when you move or click on a line
		my $syntax = $self;
		Wx::Event::EVT_LEFT_UP(
			$editor,
			sub {
				my $self  = shift;
				my $event = shift;
				$syntax->_show_current_annotation(1);
				$event->Skip(1);
			}
		);
		Wx::Event::EVT_KEY_UP(
			$editor,
			sub {
				$syntax->_show_current_annotation(1);
			}
		);
	}

	# NOTE: Recolor the document to make sure we do not accidentally
	# remove syntax highlighting while syntax checking
	$document->colourize;

	# Flush old results
	$self->clear;

	my $root = $self->{tree}->AddRoot('Root');

	# If there are no errors or warnings, clear the syntax checker pane
	unless ( Params::Util::_HASH($model) ) {

		# Relative-to-the-project filename.
		# Check that the document has been saved.
		if ( defined $filename ) {
			my $project_dir = $document->project_dir;
			if ( defined $project_dir ) {
				$project_dir = quotemeta $project_dir;
				$filename =~ s/^$project_dir[\\\/]?//;
			}
			$self->{tree}->SetItemText(
				$root,
				sprintf( Wx::gettext('No errors or warnings found in %s within %3.2f secs.'), $filename, $elapsed )
			);
		} else {
			$self->{tree}->SetItemText( $root,
				sprintf( Wx::gettext( 'No errors or warnings found within %3.2f secs.', $elapsed ) ) );
		}
		$self->{tree}->SetItemImage( $root, $self->{images}->{ok} );
		$self->set_label_bitmap('ok');
		return;
	}

	$self->{tree}->SetItemText(
		$root,
		(   defined $filename
			? sprintf(
				Wx::gettext('Found %d issue(s) in %s within %3.2f secs.'), scalar @{ $model->{issues} }, $filename,
				$elapsed
				)
			: sprintf( Wx::gettext('Found %d issue(s) within %3.2f secs.'), scalar @{ $model->{issues} }, $elapsed )
		)
	);
	$self->{tree}->SetItemImage( $root, $self->{images}->{root} );

	$self->{annotations} = ();
	my $i       = 0;
	my $worst   = 'ok';
	my $maxline = $editor->GetLineCount;
	my @issues  = sort { $a->{line} <=> $b->{line} } @{ $model->{issues} };
	ISSUE:
	foreach my $issue (@issues) {
		my $line = $issue->{line} - 1;
		if ( $line > $maxline ) {
			$line = $maxline;
		}
		my $type       = exists $issue->{type} ? $issue->{type} : 'F';
		my $marker     = $MESSAGE{$type}->{marker};
		my $is_warning = $marker == Padre::Constant::MARKER_WARN;
		$editor->MarkerAdd( $line, $marker );

		# Is this the worst thing we have encountered?
		unless ( $worst eq 'error' ) {
			if ($is_warning) {
				$worst = 'warning';
			} else {
				$worst = 'error';
			}
		}

		# Underline the syntax warning/error line with an orange or red squiggle indicator
		my $start  = $editor->PositionFromLine($line);
		my $indent = $editor->GetLineIndentPosition($line);
		my $end    = $editor->GetLineEndPosition($line);

		# Change only the indicators
		$editor->SetIndicatorCurrent(
			$is_warning ? Padre::Constant::INDICATOR_WARNING : Padre::Constant::INDICATOR_ERROR );
		$editor->IndicatorFillRange( $indent, $end - $indent );

		# Collect annotations for later display
		# One annotated line contains multiple errors/warnings
		if ($feature) {
			my $message = $issue->message;
			my $char_style =
				$is_warning
				? sprintf( '%c', Padre::Constant::PADRE_WARNING() )
				: sprintf( '%c', Padre::Constant::PADRE_ERROR() );
			unless ( $self->{annotations}->{$line} ) {
				$self->{annotations}->{$line} = {
					message => $message,
					style   => $char_style x length($message),
				};
			} else {
				$self->{annotations}->{$line}->{message} .= "\n$message";
				$self->{annotations}->{$line}->{style} .= $char_style x ( length($message) + 1 );
			}
		}

		my $item = $self->{tree}->AppendItem(
			$root,
			sprintf(
				Wx::gettext('Line %d:   (%s)   %s'),
				$line + 1,
				$MESSAGE{$type}->{label},
				$issue->{message}
			),
			$is_warning ? $self->{images}->{warning} : $self->{images}->{error}
		);
		$self->{tree}->SetPlData( $item, $issue );
	}

	$self->_show_current_annotation(0) if $feature;

	# Enable standard error output display button
	unless ( $self->{show_stderr}->IsShown ) {
		$self->{show_stderr}->Show(1);
		$self->Layout;
	}

	$self->{tree}->Expand($root);
	$self->{tree}->EnsureVisible($root);

	# Set the icon to the new state
	$self->set_label_bitmap($worst);

	return 1;
}

sub lock_update {
	my $self   = shift;
	my $lock   = $self->SUPER::lock_update;
	my $editor = $self->current->editor;
	if ($editor) {
		$lock = [ $lock, $editor->lock_update ];
	}
	return $lock;
}

sub set_label_bitmap {
	return; # Temporarily disabled
	my $self     = shift;
	my $name     = shift;
	my $icon     = $ICON{$name} or return;
	my $method   = $self->view_panel;
	my $panel    = $self->main->$method();
	my $position = $panel->GetPageIndex($self);
	$panel->SetPageBitmap( $position, $icon );
}

# Show the current line error/warning if it exists or hide the previous annotation
sub _show_current_annotation {
	my ($self, $syntax_shown)   = @_;
	my $editor = $self->main->current->editor;

	my $current_line = $editor->LineFromPosition( $editor->GetCurrentPos );
	my $annotation   = $self->{annotations}->{$current_line};
	my $visible = 0; #TODO use Wx::wxSTC_ANNOTATION_HIDDEN once it is there
	$editor->AnnotationClearAll;
	if ($annotation) {
		$editor->AnnotationSetText( $current_line, $annotation->{message} );
		$editor->AnnotationSetStyles( $current_line, $annotation->{style} );
		$visible = 2; #TODO use Wx::wxSTC_ANNOTATION_BOXED once it is there
		$self->_show_syntax_without_focus if $syntax_shown;
	}

	$editor->AnnotationSetVisible($visible);
}

# Shows the non-visible syntax check tab without
# losing focus on the editor!
sub _show_syntax_without_focus {
	my $self    = shift;
	my $current = $self->current or return;
	my $main    = $self->main;
	my $bottom  = $main->bottom;

	# Are we currently showing the page
	my $position = $bottom->GetPageIndex($main->syntax);
	if ( $position >= 0 ) {

		# Already showing, switch to it
		$bottom->SetSelection($position);
		$current->editor->SetFocus;
		return;
	}

	return;
}


# Updates the help page. It shows the text if it is defined otherwise clears and hides it
sub _update_help_page {
	my $self = shift;
	my $text = shift;

	# load the escaped HTML string into the shown page otherwise hide
	# if the text is undefined
	my $help = $self->{help};
	if ( defined $text ) {
		require CGI;
		$text = CGI::escapeHTML($text);
		$text =~ s/\n/<br>/g;
		my $WARN_TEXT = $MESSAGE{'W'}->{label};
		if ( $text =~ /^\((W\s+(\w+)|D|S|F|P|X|A)\)/ ) {
			my ( $category, $warning_category ) = ( $1, $2 );
			my $category_label = ( $category =~ /^W/ ) ? $MESSAGE{'W'}->{label} : $MESSAGE{$1}->{label};
			my $notes =
				defined($warning_category)
				? "<code>no warnings '$warning_category';    # disable</code><br>"
				. "<code>use warnings '$warning_category';   # enable</code><br><br>"
				: '';
			$text =~ s{^\((W\s+(\w+)|D|S|F|P|X|A)\)}{<h3>$category_label</h3>$notes};
		}
		$help->SetPage($text);
		$help->Show;
	} else {
		$help->SetPage('');
		$help->Hide;
	}

	# Sticky note light-yellow background
	$self->{help}->SetBackgroundColour( Wx::Colour->new( 0xFD, 0xFC, 0xBB ) );

	# Relayout to actually hide/show the help page
	$self->Layout;
}

# Selects the next problem in the editor.
# Wraps to the first one when at the end.
sub select_next_problem {
	my $self         = shift;
	my $editor       = $self->current->editor or return;
	my $current_line = $editor->LineFromPosition( $editor->GetCurrentPos );

	# Start with the first child
	my $root = $self->{tree}->GetRootItem;
	my ( $child, $cookie ) = $self->{tree}->GetFirstChild($root);
	my $line_to_select = undef;
	while ( $child->IsOk ) {

		# Get the line and check that it is a valid line number
		my $issue = $self->{tree}->GetPlData($child) or return;
		my $line = $issue->{line};

		if (   not defined($line)
			or ( $line !~ /^\d+$/o )
			or ( $line > $editor->GetLineCount ) )
		{
			( $child, $cookie ) = $self->{tree}->GetNextChild( $root, $cookie );
			next;
		}
		$line--;

		unless ($line_to_select) {

			# Record the line number of the first problem :)
			$line_to_select = $line;
		}

		if ( $line > $current_line ) {

			# Record the line number as the next line beyond the current one
			$line_to_select = $line;
			last;
		}

		# Get the next child if there is one
		( $child, $cookie ) = $self->{tree}->GetNextChild( $root, $cookie );
	}

	# Select the line in the editor
	Padre::Util::select_line_in_editor( $line_to_select, $editor ) if $line_to_select;
}

1;

# Copyright 2008-2011 The Padre development team as listed in Padre.pm.
# LICENSE
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl 5 itself.

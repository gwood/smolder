package Smolder::Control;
use strict;
use warnings;
use base 'CGI::Application';
use CGI::Application::Plugin::Apache qw(:all);
use CGI::Application::Plugin::ValidateRM;
use CGI::Application::Plugin::TT;
#use CGI::Application::Plugin::DebugScreen;
use CGI::Application::Plugin::HTMLPrototype;
use Smolder::Util;
use File::Spec::Functions qw(catdir catfile);

use Smolder::Conf qw(InstallRoot DBName DBUser DBPass);
use Smolder::DB::Developer;


# it's all dynamic, so don't let the browser cache anything
__PACKAGE__->add_callback(
    init => sub {
        my $self = shift;
        $self->param('r')->no_cache(1);
    }
);

=head1 NAME

Smolder::Control

=head1 DESCRIPTION

This module serves as a base class for all controller classes in smolder. As such
it defines some behavior with regard to templates, form validation, etc
and provides some utility methods for accessing this data.

=head1 METHODS

=head2 developer

This method will return the L<Smolder::DB::Developer> object that this request 
is associated with, if it's not a public request. This information is pulled 
from the C<$ENV{REMOTE_USER}> which is set by C<mod_auth_tkt>.

=cut

sub developer {
    my $self = shift;
    # REMOTE_USER is set bv mod_auth_tkt
    return Smolder::DB::Developer->retrieve(
        $ENV{REMOTE_USER}
    );
}

=head2 error_message

A simple run mode to display an error message. This should not be used to show expected
messages, but rather to display un-recoverable and un-expected occurances.

=cut

sub error_message {
    my ($self, $msg) = @_;
    warn "An error occurred: $msg";
    return $self->tt_process(
        'error_message.tmpl',
        {
            message => $msg,
        },
    );
}

=head2 tt_process

This method is provided by the L<CGI::Application::Plugin::TT> plugin. It is used
to choose and process the Template Toolkit templates. If no name is provided for the
template (as the first argument) then the package name and the run mode will be used
to determine which template to use. For instance:

    $self->tt_process({ arg1 => 'foo', arg2 => 'bar' });

If this was done in the 'Smolder::Control::Foo' package for the 'list' run mode then
it would use the F<templates/Foo/list.tmpl> template. If you want to use a different template
then you can explicitly specify it as well:

    $self->tt_process('Foo/list.tmpl', { arg1 => 'foo', arg2 => 'bar' });

See L<TEMPLATE_CONFIGURATION> for more details.

=head2 dfv_msgs

This is a convenience method to get access to the last L<Data::FormValidator> messages
that were created due to a form validation failure. These messages are simply flags indicating
which fields were missinage, which failed their constraints and which constraints failed.

See L<FORM VALIDATION> for more information.

=cut

sub dfv_msgs {
    my $self = shift;
    my $results;
    # we need to eval{} 'cause ValidateRM doesn't like dfv_results() being called
    # without check_rm() being called first.
    eval { $results = $self->dfv_results };
    if( ! $@ ) {
        return $results->msgs();
    } else {
        return {};
    }
}

=head1 TEMPLATE CONFIGURATION

As mentioned above, template access/control is performed through the
L<CGI::Application::Plugin::TT> plugin. The important are the settings used:

=over

=item The search path of templates is F<InstallRoot/templates>

=item All templates are wrapped with the F<templates/wrapper.tmpl>
template unless the C<ajax> CGI param is set.

=item Recursion is allowed for template INCLUDE and PROCESS

=item The following FILTERS are available to each template:

=over

=item pass_fail_color

Given a percentage (usually of passing tests to the total number run)
this filter will return an HTML RGB color suitable for a colorful indicator
of performance.

=back

=back

=cut

# configuration options for CAP::TT (Template Toolkit)
my $TT_CONFIG = {
    TEMPLATE_OPTIONS => {
        COMPILE_DIR  => catdir( InstallRoot, 'tmp' ),
        INCLUDE_PATH => catdir( InstallRoot, 'templates' ),
        COMPILE_EXT  => '.ttc',
        WRAPPER      => 'wrapper.tmpl',
        RECURSION    => 1,
        FILTERS      => {
            pass_fail_color => \&Smolder::Util::pass_fail_color,
        },
    },
    TEMPLATE_NAME_GENERATOR => sub {
        my $self = shift;
        # the directory is based on the object's package name
        my $mod = ref $self;
        $mod =~ s/Smolder::Control:://;
        my $dir = catdir(split(/::/, $mod));

        # the filename is the method name of the caller
        (caller(2))[3] =~ /([^:]+)$/;
        my $name = $1;
        if ($name eq 'tt_process') {
            # we were called from tt_process, so go back once more on the caller stack
            (caller(3))[3] =~ /([^:]+)$/;
            $name = $1;
        }
        return catfile($dir, $name.'.tmpl');
    }
};
__PACKAGE__->tt_config($TT_CONFIG);

__PACKAGE__->add_callback('tt_pre_process', sub {
    my ($self, $file, $vars) = @_;
    if( $self->query->param('ajax') ) {
        $vars->{no_wrapper} = 1;
        $vars->{ajax} = 1;
    }
    return;
});



=head1 FORM VALIDATION

For form validation we use L<CGI::Application::Plugin::ValidateRM> which in
turn uses L<Data::FormValidator>. We further customize the validation by
providing the C<untaint_all_constraints> option which means that some values
will become "transformed" (dates will become L<DateTime> objects, etc).

We also customize the resulting hash of messages that is generated upon
validation failure. All failed and missing constraints will become err_$field. All
fields that were present but failed a constraint will become invalid_$name 
(where $name is the name of the field or the name of the constraint if it's 
named). And all missing constraints will have a missing_$field message. 
Also, the 'any_errors' message will be set.

=cut

__PACKAGE__->add_callback(
    init => sub {
        my $self = shift;
        my $query = $self->query();
        $self->param( 
            'dfv_defaults' => { 
                msgs                    => \&_create_dfv_msgs,
                untaint_all_constraints => 1,
            } 
        );
    }
);

sub _create_dfv_msgs {
    my $dfv = shift;
    my %msgs;
    # if there's anything wrong
    if( ! $dfv->success ) {
        # add 'any_errors'
        $msgs{any_errors} = 1;

        if( $dfv->has_invalid ) {
            # add any error messages for failed (possibly named) constraints
            foreach my $failed ($dfv->invalid) {
                $msgs{"err_$failed"} = 1;
                $msgs{"invalid_$failed"} = 1;
                my $names = $dfv->invalid($failed);
                foreach my $name (@$names) {
                    next if( ref $name ); # skip regexes
                    $msgs{"invalid_$name"} = 1;
                }
            }
        }

        # now add for missing
        if( $dfv->has_missing ) {
            foreach my $missing ($dfv->missing) {
                $msgs{"err_$missing"} = 1;
                $msgs{"missing_$missing"} = 1;
            }
        }
    }
    return \%msgs;
}


1;
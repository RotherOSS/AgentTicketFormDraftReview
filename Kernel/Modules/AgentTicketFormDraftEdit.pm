# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::Modules::AgentTicketFormDraftEdit;

use v5.24;
use strict;
use warnings;

# core modules

# CPAN modules

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);
use Kernel::Language              qw(Translatable);
use Mail::Address                 ();

our $ObjectManagerDisabled = 1;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = bless {%Param}, $Type;

    # get form id
    $Self->{FormID} = $Kernel::OM->Get('Kernel::System::Web::FormCache')->PrepareFormID(
        ParamObject  => $Kernel::OM->Get('Kernel::System::Web::Request'),
        LayoutObject => $Kernel::OM->Get('Kernel::Output::HTML::Layout'),
    );

    $Self->{AccessRo} = $Param{AccessRo};
    $Self->{AccessRw} = $Param{AccessRw};

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');

    # get Ticket and FormDraftID
    my $TicketID    = $ParamObject->GetParam( Param => 'TicketID' );
    my $FormDraftID = $ParamObject->GetParam( Param => 'FormDraftID' );

    # check needed stuff
    if ( !$TicketID || !$FormDraftID ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('Need TicketID and FormDraftID!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    # get config of frontend module
    my $Config = $ConfigObject->Get("Ticket::Frontend::$Self->{Action}");

    # check permissions
    # first check at frontend level and then at ticket level
    # frontend permissions overwrite ticket level permissions
    my @AllowedAccessModes;
    if ( $Self->{AccessRw} ) {
        @AllowedAccessModes = qw(rw ro);
    }
    elsif ( $Self->{AccessRo} ) {
        @AllowedAccessModes = qw(ro);
    }
    else {
        # error screen, there is no frontend permission to this module
        return $LayoutObject->NoPermission(
            Message    => $LayoutObject->{LanguageObject}->Translate('You have no permissions!'),
            WithHeader => 'yes',
        );
    }
    ACCESS:
    for my $AccessType (@AllowedAccessModes) {
        if (
            $TicketObject->TicketPermission(
                Type     => $AccessType,
                TicketID => $TicketID,
                UserID   => $Self->{UserID},
                LogNo    => 1,
            )
            )
        {
            $Self->{AccessMode} = $AccessType;

            last ACCESS;
        }
    }

    # error screen, don't show ticket
    if ( !$Self->{AccessMode} ) {
        return $LayoutObject->NoPermission(
            Message    => $LayoutObject->{LanguageObject}->Translate('You have no permissions!'),
            WithHeader => 'yes',
        );
    }

    # get ACL restrictions
    my %PossibleActions = ( 1 => $Self->{Action} );

    my $ACL = $TicketObject->TicketAcl(
        Data          => \%PossibleActions,
        Action        => $Self->{Action},
        TicketID      => $TicketID,
        ReturnType    => 'Action',
        ReturnSubType => '-',
        UserID        => $Self->{UserID},
    );
    my %AclAction = $TicketObject->TicketAclActionData();

    # check if ACL restrictions exist
    if ($ACL) {
        my %AclActionLookup = reverse %AclAction;

        # show error screen if ACL prohibits this action
        if ( !$AclActionLookup{ $Self->{Action} } ) {
            return $LayoutObject->NoPermission( WithHeader => 'yes' );
        }
    }

    my $FormDraftObject   = $Kernel::OM->Get('Kernel::System::FormDraft');
    my $UploadCacheObject = $Kernel::OM->Get('Kernel::System::Web::UploadCache');

    my $FormDraft = $FormDraftObject->FormDraftGet(
        FormDraftID => $FormDraftID,
        ObjectID    => $TicketID,
        UserID      => $Self->{UserID},
    );

    # Check for failed draft loading request.
    if ( !$FormDraft->{FormDraftID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('Loading draft failed!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    if ( !$Self->{Subaction} ) {

        my %Ticket = $TicketObject->TicketGet(
            TicketID => $TicketID
        );

        # Prepare To, Cc and Bcc from form data
        my $To  = '';
        my $Cc  = '';
        my $Bcc = '';

        my $CustomersNumberTo = $FormDraft->{FormData}->{CustomerTicketCounterToCustomer} || 0;

        if ($CustomersNumberTo) {
            my $CustomerCounter = 1;

            COUNT:
            for my $Count ( 1 .. $CustomersNumberTo ) {
                last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

                my $CustomerElement = $FormDraft->{FormData}->{ 'CustomerTicketText_' . $Count };

                next COUNT unless $CustomerElement;

                if ($To) {
                    $To .= ', ' . $CustomerElement;
                }
                else {
                    $To = $CustomerElement;
                }
            }
        }

        my $CustomersNumberCc = $FormDraft->{FormData}->{CustomerTicketCounterCcCustomer} || 0;

        if ($CustomersNumberCc) {
            my $CustomerCounterCc = 1;

            COUNT:
            for my $Count ( 1 .. $CustomersNumberCc ) {
                last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

                my $CustomerElementCc = $FormDraft->{FormData}->{ 'CcCustomerTicketText_' . $Count };

                next COUNT unless $CustomerElementCc;

                if ($Cc) {
                    $Cc .= ', ' . $CustomerElementCc;
                }
                else {
                    $Cc = $CustomerElementCc;
                }
            }
        }

        my $CustomersNumberBcc = $FormDraft->{FormData}->{CustomerTicketCounterBccCustomer} || 0;

        if ($CustomersNumberBcc) {
            my $CustomerCounterBcc = 1;

            COUNT:
            for my $Count ( 1 .. $CustomersNumberBcc ) {
                last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

                my $CustomerElementBcc = $FormDraft->{FormData}->{ 'BccCustomerTicketText_' . $Count };

                next COUNT unless $CustomerElementBcc;

                if ($Bcc) {
                    $Bcc .= ', ' . $CustomerElementBcc;
                }
                else {
                    $Bcc = $CustomerElementBcc;
                }
            }
        }

        # add UploadCache data
        for my $File ( @{ $FormDraft->{FileData} } ) {
            return unless $UploadCacheObject->FormIDAddFile(
                %{$File},
                FormID => $Self->{FormID},
            );
        }

        my $Output = $LayoutObject->Header(
            Value     => $Ticket{TicketNumber},
            Type      => 'Small',
            BodyClass => 'Popup',
        );

        # When a draft is loaded, inform a user that article subject will be empty
        # if contains only the ticket hook (if nothing is modified).
        $Output .= $LayoutObject->Notify(
            Data => $LayoutObject->{LanguageObject}->Translate(
                'Article subject will be empty if the subject contains only the ticket hook!'
            ),
        );

        my $From = $Kernel::OM->Get('Kernel::System::TemplateGenerator')->Sender(
            QueueID => $Ticket{QueueID},
            UserID  => $Self->{UserID},
        );
        my @Attachments = $UploadCacheObject->FormIDGetAllFilesMeta(
            FormID => $Self->{FormID},
        );

        $Output .= $Self->_Mask(
            TicketID    => $TicketID,
            Attachments => \@Attachments,
            FormDraftID => $FormDraftID,
            To          => $To,
            Cc          => $Cc,
            Bcc         => $Bcc,
            From        => $From,
            FormDraft   => $FormDraft,
        );
        $Output .= $LayoutObject->Footer(
            Type => 'Small',
        );
        return $Output;
    }

    elsif ( $Self->{Subaction} eq 'FormDraftUpdate' ) {

        # challenge token check for write action
        $LayoutObject->ChallengeTokenCheck();

        my %FormDraftResponse;
        my $FormDraftActionOk = $Self->_UpdateFormDraft(
            UserID      => $Self->{UserID},
            ObjectType  => 'Ticket',
            ObjectID    => $TicketID,
            FormDraftID => $FormDraftID,
            FormID      => $Self->{FormID},
            FormDraft   => $FormDraft,
        );
        if ($FormDraftActionOk) {
            $FormDraftResponse{Success} = 1;
        }
        else {
            %FormDraftResponse = (
                Success      => 0,
                ErrorMessage => 'Could not perform requested draft action!',
            );
        }

        # build JSON output
        my $JSON = $LayoutObject->JSONEncode(
            Data => \%FormDraftResponse,
        );

        # send JSON response
        return $LayoutObject->Attachment(
            ContentType => 'application/json',
            Content     => $JSON,
            Type        => 'inline',
            NoCache     => 1,
        );
    }
}

sub _Mask {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get config for frontend module
    my $Config = $ConfigObject->Get("Ticket::Frontend::$Self->{Action}");

    $LayoutObject->Block(
        Name => 'TicketBack',
    );

    # add rich text editor
    if ( $LayoutObject->{BrowserRichText} ) {

        # use height/width defined for this screen
        $Param{RichTextHeight} = $Config->{RichTextHeight} || 0;
        $Param{RichTextWidth}  = $Config->{RichTextWidth}  || 0;

        # set up rich text editor
        $LayoutObject->SetRichTextParameters(
            Data => \%Param,
        );
    }

    # show attachments
    ATTACHMENT:
    for my $Attachment ( @{ $Param{Attachments} } ) {
        if (
            $Attachment->{ContentID}
            && $LayoutObject->{BrowserRichText}
            && ( $Attachment->{ContentType} =~ /image/i )
            && ( $Attachment->{Disposition} eq 'inline' )
            )
        {
            next ATTACHMENT;
        }

        push @{ $Param{AttachmentList} }, $Attachment;
    }
    my @Articles = $Kernel::OM->Get('Kernel::System::Ticket::Article')->ArticleList(
        TicketID => $Param{TicketID},
        OnlyLast => 1,
    );

    if (@Articles) {
        my $LastArticle = $Articles[0];

        my $LastArticleSystemTime;
        if ( $LastArticle->{CreateTime} ) {
            my $LastArticleSystemTimeObject = $Kernel::OM->Create(
                'Kernel::System::DateTime',
                ObjectParams => {
                    String => $LastArticle->{CreateTime},
                },
            );
            $LastArticleSystemTime = $LastArticleSystemTimeObject->ToEpoch();
        }

        my $FormDraftSystemTimeObject = $Kernel::OM->Create(
            'Kernel::System::DateTime',
            ObjectParams => {
                String => $Param{FormDraft}->{ChangeTime},
            },
        );
        my $FormDraftSystemTime = $FormDraftSystemTimeObject->ToEpoch();

        if ( !$LastArticleSystemTime || $FormDraftSystemTime <= $LastArticleSystemTime ) {
            $Param{FormDraftOutdated} = 1;
        }
    }
    $Param{FormDraft}->{ChangeByName} = $Kernel::OM->Get('Kernel::System::User')->UserName(
        UserID => $Param{FormDraft}->{ChangeBy},
    );
    if ( $Self->{AccessMode} ne "rw" ) {
        $Param{ReadOnly}      = 'readonly';
        $Param{ReadOnlyClass} = 'Readonly';
    }

    $LayoutObject->Block(
        Name => 'ToCustomer',
        Data => {
            ToCustomer => $Param{To}
        }
    );
    $LayoutObject->Block(
        Name => 'CcCustomer',
        Data => {
            Cc => $Param{Cc}
        }
    );
    $LayoutObject->Block(
        Name => 'BccCustomer',
        Data => {
            Bcc => $Param{Bcc}
        }
    );

    # create & return output
    return $LayoutObject->Output(
        TemplateFile => 'AgentTicketFormDraftEdit',
        Data         => {
            FormID         => $Self->{FormID},
            FormDraftID    => $Param{FormDraftID},
            ResponseFormat => $Param{FormDraft}->{FormData}->{Body},
            Subject        => $Param{FormDraft}->{FormData}->{Subject},
            %Param,
        },
    );
}

sub _UpdateFormDraft {
    my ( $Self, %Param ) = @_;

    # check params
    return if !$Param{UserID} || !$Param{ObjectType} || !IsInteger( $Param{ObjectID} );

    my $FormDraft = $Param{FormDraft};
    my %FormData  = $FormDraft->{FormData}->%*;

    PARAM:
    for my $Param (qw(Subject Body)) {
        my @Values = $Kernel::OM->Get('Kernel::System::Web::Request')->GetParam( Param => $Param );
        $FormData{$Param} = $Values[0];
    }

    # get files from upload cache
    my @FileData = $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDGetAllFilesData(
        FormID => $Param{FormID},
    );

    # prepare data to add or update draft
    my %FormDraft = (
        FormData    => \%FormData,
        FileData    => \@FileData,
        FormDraftID => $Param{FormDraftID},
        ObjectType  => $Param{ObjectType},
        ObjectID    => $Param{ObjectID},
        Action      => $FormDraft->{Action},
        Title       => $FormDraft->{Title},
        UserID      => $Param{UserID},
    );

    # update draft
    return $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftUpdate(%FormDraft);
}

1;

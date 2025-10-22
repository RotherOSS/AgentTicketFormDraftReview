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
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    $Self->{FormID} = $Kernel::OM->Get('Kernel::System::Web::FormCache')->PrepareFormID(
        ParamObject  => $ParamObject,
        LayoutObject => $LayoutObject,
    );

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
    ACCESS:
    for my $AccessType (qw(rw ro)) {
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

    my %Ticket = $TicketObject->TicketGet(
        TicketID => $TicketID
    );

    if ( !$Self->{Subaction} ) {

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
            TicketID       => $TicketID,
            ResponseFormat => $FormDraft->{FormData}->{Body},
            Attachments    => \@Attachments,
            FormDraftID    => $FormDraftID,
            To             => $To,
            Cc             => $Cc,
            Bcc            => $Bcc,
            From           => $From,
            Subject        => $FormDraft->{FormData}->{Subject},
        );
        $Output .= $LayoutObject->Footer(
            Type => 'Small',
        );
        return $Output;
    }

    elsif ( $Self->{Subaction} eq 'FormDraftUpdate' ) {

        # challenge token check for write action
        if ( !$FormDraftID ) {
            $LayoutObject->ChallengeTokenCheck();
        }

        my %FormDraftResponse;
        my $FormDraftActionOk = $Self->_UpdateFormDraft(
            UserID     => $Self->{UserID},
            ObjectType => 'Ticket',
            ObjectID   => $TicketID,
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

    my $LoadedFormDraft;
    $LoadedFormDraft = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftGet(
        FormDraftID => $Param{FormDraftID},
        GetContent  => 0,
        ObjectID    => $Param{TicketID},
        UserID      => $Self->{UserID},
    );

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
                String => $LoadedFormDraft->{ChangeTime},
            },
        );
        my $FormDraftSystemTime = $FormDraftSystemTimeObject->ToEpoch();

        if ( !$LastArticleSystemTime || $FormDraftSystemTime <= $LastArticleSystemTime ) {
            $Param{FormDraftOutdated} = 1;
        }
    }

    if ( IsHashRefWithData($LoadedFormDraft) ) {

        $LoadedFormDraft->{ChangeByName} = $Kernel::OM->Get('Kernel::System::User')->UserName(
            UserID => $LoadedFormDraft->{ChangeBy},
        );
    }

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
            FormDraft      => $Config->{FormDraft},
            FormDraftID    => $Param{FormDraftID},
            FormDraftTitle => $LoadedFormDraft ? $LoadedFormDraft->{Title} : '',
            FormDraftMeta  => $LoadedFormDraft,
            %Param,
        },
    );
}

sub _UpdateFormDraft {
    my ( $Self, %Param ) = @_;

    # check params
    return if !$Param{UserID} || !$Param{ObjectType} || !IsInteger( $Param{ObjectID} );

    # create necessary objects
    my $ParamObject     = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $DraftFormObject = $Kernel::OM->Get('Kernel::System::FormDraft');

    # gather necessary data for backend
    my %MetaParams;
    for my $Param (qw(Action FormDraftID FormDraftTitle FormID)) {
        $MetaParams{$Param} = $ParamObject->GetParam(
            Param => $Param,
        );
    }
    return unless $MetaParams{Action};

    # determine session name param (SessionUseCookie = 0) for exclusion
    my $SessionName = $Kernel::OM->Get('Kernel::Config')->Get('SessionName') || 'SessionID';

    # compile override list
    my %OverrideParams = IsHashRefWithData( $Param{OverrideParams} ) ? %{ $Param{OverrideParams} } : ();

    # these params must always be excluded for safety, they take precedence
    for my $Name (
        qw(Action ChallengeToken FormID FormDraftID FormDraftTitle FormDraftAction LoadFormDraftID),
        $SessionName
        )
    {
        $OverrideParams{$Name} = undef;
    }

    # Gather all params.
    #   Exclude, add or override by using OverrideParams if necessary.
    my @ParamNames = $ParamObject->GetParamNames();
    my %ParamSeen;

    my $FormDraft = ($DraftFormObject)->FormDraftGet(
        FormDraftID => $MetaParams{FormDraftID},
        ObjectID    => $Param{ObjectID},
        UserID      => $Param{UserID},
    );
    my %FormData = $FormDraft->{FormData}->%*;

    PARAM:
    for my $Param ( @ParamNames, sort keys %OverrideParams ) {

        next PARAM if $ParamSeen{$Param}++;
        my $Value;

        # check for overrides first
        if ( exists $OverrideParams{$Param} ) {

            # allow only strings and array references as value
            if (
                IsStringWithData( $OverrideParams{$Param} )
                || IsArrayRefWithData( $OverrideParams{$Param} )
                )
            {
                $Value = $OverrideParams{$Param};
            }

            # skip all other parameters (including those specified to be excluded by using 'undef')
            else {
                next PARAM;
            }
        }

        # get other values from param object
        if ( !defined $Value ) {
            my @Values = $ParamObject->GetArray( Param => $Param );
            next PARAM unless IsArrayRefWithData( \@Values );

            # store single occurances as string
            if ( scalar @Values == 1 ) {
                $Value = $Values[0];
            }

            # store multiple occurances as array reference
            else {
                $Value = \@Values;
            }
        }

        $FormData{$Param} = $Value;
    }

    # get files from upload cache
    my @FileData = $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDGetAllFilesData(
        FormID => $MetaParams{FormID},
    );

    # prepare data to add or update draft
    my %FormDraft = (
        FormData    => \%FormData,
        FileData    => \@FileData,
        FormDraftID => $MetaParams{FormDraftID},
        ObjectType  => $Param{ObjectType},
        ObjectID    => $Param{ObjectID},
        Action      => $FormDraft->{Action},
        Title       => $MetaParams{FormDraftTitle},
        UserID      => $Param{UserID},
    );

    # update draft
    if ( $MetaParams{FormDraftID} ) {
        return unless $DraftFormObject->FormDraftUpdate(%FormDraft);
        return 1;
    }
}

1;

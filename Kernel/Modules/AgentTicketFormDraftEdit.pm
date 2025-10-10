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

    my $ParamObject = $Kernel::OM->Get('Kernel::System::Web::Request');

    # Try to load draft if requested.
    if (
        $Kernel::OM->Get('Kernel::Config')->Get("Ticket::Frontend::$Self->{Action}")->{FormDraft}
        && $ParamObject->GetParam( Param => 'LoadFormDraft' )
        && $ParamObject->GetParam( Param => 'FormDraftID' )
        )
    {
        $Self->{LoadedFormDraftID} = $ParamObject->LoadFormDraft(
            FormDraftID => $ParamObject->GetParam( Param => 'FormDraftID' ),
            UserID      => $Self->{UserID},
            ObjectID    => 309,
        );
    }

    $Self->{Debug} = $Param{Debug} || 0;

    # frontend specific config
    my $Config = $Kernel::OM->Get('Kernel::Config')->Get("Ticket::Frontend::$Self->{Action}");

    my $Definition = $Kernel::OM->Get('Kernel::System::Ticket::Mask')->DefinitionGet(
        Mask => $Self->{Action},
    ) || {};

    $Self->{MaskDefinition} = $Definition->{Mask};

    # get form id
    $Self->{FormID} = $Kernel::OM->Get('Kernel::System::Web::FormCache')->PrepareFormID(
        ParamObject  => $Kernel::OM->Get('Kernel::System::Web::Request'),
        LayoutObject => $Kernel::OM->Get('Kernel::Output::HTML::Layout'),
    );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject  = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $TicketObject  = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ConfigObject  = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject   = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $MainObject    = $Kernel::OM->Get('Kernel::System::Main');

    # check needed stuff
    if ( !$Self->{TicketID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('No TicketID is given!'),
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
                TicketID => $Self->{TicketID},
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
        TicketID      => $Self->{TicketID},
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

    # Check for failed draft loading request.
    if (
        $ParamObject->GetParam( Param => 'LoadFormDraft' )
        && !$Self->{LoadedFormDraftID}
        )
    {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('Loading draft failed!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    my %Ticket = $TicketObject->TicketGet(
        TicketID      => $Self->{TicketID}
    );

    # get lock state
    my $TicketBackType = 'TicketBack';
    if ( $Config->{RequiredLock} ) {
        if ( !$TicketObject->TicketLockGet( TicketID => $Self->{TicketID} ) ) {

            my $Lock = $TicketObject->TicketLockSet(
                TicketID => $Self->{TicketID},
                Lock     => 'lock',
                UserID   => $Self->{UserID}
            );

            # Set new owner if ticket owner is different then logged user.
            if ( $Lock && ( $Ticket{OwnerID} != $Self->{UserID} ) ) {

                # Remember previous owner, which will be used to restore ticket owner on undo action.
                $Ticket{PreviousOwner} = $Ticket{OwnerID};

                my $Success = $TicketObject->TicketOwnerSet(
                    TicketID  => $Self->{TicketID},
                    UserID    => $Self->{UserID},
                    NewUserID => $Self->{UserID},
                );

                # Show lock state.
                if ( !$Success ) {
                    return $LayoutObject->FatalError();
                }
            }

            $TicketBackType .= 'Undo';
        }
    }

    my $ArticleBackendObject = $ArticleObject->BackendForChannel( ChannelName => 'Email' );

    # get params
    my %GetParam;
    for (
        qw(
            To Cc Bcc Subject Body InReplyTo References ResponseID ReplyArticleID StateID ArticleID
            IsVisibleForCustomerPresent IsVisibleForCustomer TimeUnits Year Month Day Hour Minute FormID ReplyAll
            FormDraftID Title
        )
        )
    {
        $GetParam{$_} = $ParamObject->GetParam( Param => $_ );
    }

    # Make sure sender is correct one. See bug#14872 ( https://bugs.otrs.org/show_bug.cgi?id=14872 ).
    $GetParam{From} = $Kernel::OM->Get('Kernel::System::TemplateGenerator')->Sender(
        QueueID => $Ticket{QueueID},
        UserID  => $Self->{UserID},
    );

    my $CustomersNumberTo = $ParamObject->GetParam( Param => 'CustomerTicketCounterToCustomer' ) || 0;

    # get check item object
    my $CheckItemObject = $Kernel::OM->Get('Kernel::System::CheckItem');

    if ($CustomersNumberTo) {
        my $CustomerCounter = 1;

        COUNT:
        for my $Count ( 1 .. $CustomersNumberTo ) {
            last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

            my $CustomerElement = $ParamObject->GetParam( Param => 'CustomerTicketText_' . $Count );

            next COUNT unless $CustomerElement;

            if ( $GetParam{To} ) {
                $GetParam{To} .= ', ' . $CustomerElement;
            }
            else {
                $GetParam{To} = $CustomerElement;
            }
        }
    }

    my $CustomersNumberCc = $ParamObject->GetParam( Param => 'CustomerTicketCounterCcCustomer' ) || 0;

    if ($CustomersNumberCc) {
        my $CustomerCounterCc = 1;

        COUNT:
        for my $Count ( 1 .. $CustomersNumberCc ) {
            last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

            my $CustomerElementCc = $ParamObject->GetParam( Param => 'CcCustomerTicketText_' . $Count );

            next COUNT unless $CustomerElementCc;

            if ( $GetParam{Cc} ) {
                $GetParam{Cc} .= ', ' . $CustomerElementCc;
            }
            else {
                $GetParam{Cc} = $CustomerElementCc;
            }
        }
    }

    my $CustomersNumberBcc = $ParamObject->GetParam( Param => 'CustomerTicketCounterBccCustomer' ) || 0;

    if ($CustomersNumberBcc) {
        my $CustomerCounterBcc = 1;

        COUNT:
        for my $Count ( 1 .. $CustomersNumberBcc ) {
            last COUNT if $Count > 1_000;    # bail out when the number of customers is abnormally high

            my $CustomerElementBcc = $ParamObject->GetParam( Param => 'BccCustomerTicketText_' . $Count );

            next COUNT unless $CustomerElementBcc;

            if ( $GetParam{Bcc} ) {
                $GetParam{Bcc} .= ', ' . $CustomerElementBcc;
            }
            else {
                $GetParam{Bcc} = $CustomerElementBcc;
            }
        }
    }

    # transform pending time, time stamp based on user time zone
    if (
        defined $GetParam{Year}
        && defined $GetParam{Month}
        && defined $GetParam{Day}
        && defined $GetParam{Hour}
        && defined $GetParam{Minute}
        )
    {
        %GetParam = $LayoutObject->TransformDateSelection(
            %GetParam,
        );
    }

    # get upload cache object
    my $UploadCacheObject = $Kernel::OM->Get('Kernel::System::Web::UploadCache');

    # send email
    if ( $Self->{Subaction} eq 'SendEmail' || $Self->{LoadedFormDraftID} ) {

        # challenge token check for write action
        if ( !$Self->{LoadedFormDraftID} ) {
            $LayoutObject->ChallengeTokenCheck();
        }

        # get valid state id
        if ( !$GetParam{StateID} ) {
            my %Ticket = $TicketObject->TicketGet(
                TicketID => $Self->{TicketID},
                UserID   => 1,
            );
            $GetParam{StateID} = $Ticket{StateID};
        }

        my %StateData = $Kernel::OM->Get('Kernel::System::State')->StateGet( ID => $GetParam{StateID} );

        my %Error;

        # get check item object
        my $CheckItemObject = $Kernel::OM->Get('Kernel::System::CheckItem');

        # get all attachments meta data
        my @Attachments = $UploadCacheObject->FormIDGetAllFilesMeta(
            FormID => $Self->{FormID},
        );

        # Get and validate draft action.
        my $FormDraftAction = $ParamObject->GetParam( Param => 'FormDraftAction' );
        if ( $FormDraftAction && !$Config->{FormDraft} ) {
            return $LayoutObject->ErrorScreen(
                Message => Translatable('FormDraft functionality disabled!'),
                Comment => Translatable('Please contact the administrator.'),
            );
        }

        my %FormDraftResponse;

        # Check draft name.
        if (
            $FormDraftAction
            &&
            ( $FormDraftAction eq 'Add' || $FormDraftAction eq 'Update' )
            )
        {
            my $Title = $ParamObject->GetParam( Param => 'FormDraftTitle' );

            # A draft name is required.
            if ( !$Title ) {

                %FormDraftResponse = (
                    Success      => 0,
                    ErrorMessage => $Kernel::OM->Get('Kernel::Language')->Translate("Draft name is required!"),
                );
            }

            # Chosen draft name must be unique.
            else {
                my $FormDraftList = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftListGet(
                    ObjectType => 'Ticket',
                    ObjectID   => $Self->{TicketID},
                    Action     => $Self->{Action},
                    UserID     => $Self->{UserID},
                );
                DRAFT:
                for my $FormDraft ( @{$FormDraftList} ) {

                    # No existing draft with same name.
                    next DRAFT if $Title ne $FormDraft->{Title};

                    # Same name for update on existing draft.
                    if (
                        $GetParam{FormDraftID}
                        && $FormDraftAction eq 'Update'
                        && $GetParam{FormDraftID} eq $FormDraft->{FormDraftID}
                        )
                    {
                        next DRAFT;
                    }

                    # Another draft with the chosen name already exists.
                    %FormDraftResponse = (
                        Success      => 0,
                        ErrorMessage => $Kernel::OM->Get('Kernel::Language')->Translate( "FormDraft name %s is already in use!", $Title ),
                    );
                    last DRAFT;
                }
            }
        }

        # Perform draft action instead of saving form data in ticket/article.
        if ( $FormDraftAction && !%FormDraftResponse ) {

            # Reset FormDraftID to prevent updating existing draft.
            if ( $FormDraftAction eq 'Add' && $GetParam{FormDraftID} ) {

                # meddling with the innards of Kernel::System::Web::Request
                $ParamObject->SetArray(
                    Param  => 'FormDraftID',
                    Values => ['']
                );
            }

            my $FormDraftActionOk;
            if (
                $FormDraftAction eq 'Add'
                ||
                ( $FormDraftAction eq 'Update' && $GetParam{FormDraftID} )
                )
            {
                $FormDraftActionOk = $Self->_UpdateFormDraft(
                    UserID     => $Self->{UserID},
                    ObjectType => 'Ticket',
                    ObjectID   => $Self->{TicketID},
                );
            }
            elsif ( $FormDraftAction eq 'Delete' && $GetParam{FormDraftID} ) {
                $FormDraftActionOk = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftDelete(
                    FormDraftID => $GetParam{FormDraftID},
                    UserID      => $Self->{UserID},
                );
            }

            if ($FormDraftActionOk) {
                $FormDraftResponse{Success} = 1;
            }
            else {
                %FormDraftResponse = (
                    Success      => 0,
                    ErrorMessage => 'Could not perform requested draft action!',
                );
            }
        }

        # Return JSON when there already is a response
        if (%FormDraftResponse) {

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

        # check subject
        if ( !$GetParam{Subject} ) {
            $Error{SubjectInvalid} = ' ServerError';
        }

        # check body
        if ( !$GetParam{Body} ) {
            $Error{BodyInvalid} = ' ServerError';
        }

        # check time units
        if (
            $ConfigObject->Get('Ticket::Frontend::AccountTime')
            && $ConfigObject->Get('Ticket::Frontend::NeedAccountedTime')
            && $GetParam{TimeUnits} eq ''
            )
        {
            $Error{TimeUnitsInvalid} = 'ServerError';
        }

        # prepare subject
        my $Tn = $TicketObject->TicketNumberLookup( TicketID => $Self->{TicketID} );
        $GetParam{Subject} = $TicketObject->TicketSubjectBuild(
            TicketNumber => $Tn,
            Subject      => $GetParam{Subject} || '',
        );

        my %ArticleParam;

        # run compose modules
        if ( ref $ConfigObject->Get('Ticket::Frontend::ArticleComposeModule') eq 'HASH' ) {

            # use ticket QueueID in compose modules
            $GetParam{QueueID} = $Ticket{QueueID};

            my %Jobs = %{ $ConfigObject->Get('Ticket::Frontend::ArticleComposeModule') };
            for my $Job ( sort keys %Jobs ) {

                # load module
                if ( !$MainObject->Require( $Jobs{$Job}->{Module} ) ) {
                    return $LayoutObject->FatalError();
                }
                my $Object = $Jobs{$Job}->{Module}->new( %{$Self}, Debug => $Self->{Debug} );

                my $Multiple;

                # get params
                PARAMETER:
                for my $Parameter ( $Object->Option( %GetParam, Config => $Jobs{$Job} ) ) {
                    if ( $Jobs{$Job}->{ParamType} && $Jobs{$Job}->{ParamType} ne 'Single' ) {
                        @{ $GetParam{$Parameter} } = $ParamObject->GetArray( Param => $Parameter );
                        $Multiple = 1;
                        next PARAMETER;
                    }

                    $GetParam{$Parameter} = $ParamObject->GetParam( Param => $Parameter );
                }

                # run module
                $Object->Run(
                    %GetParam,
                    StoreNew => 1,
                    Config   => $Jobs{$Job}
                );

                # get options that have been removed from the selection
                # and add them back to the selection so that the submit
                # will contain options that were hidden from the agent
                my $Key = $Object->Option( %GetParam, Config => $Jobs{$Job} );

                if ( $Object->can('GetOptionsToRemoveAJAX') ) {
                    my @RemovedOptions = $Object->GetOptionsToRemoveAJAX(%GetParam);
                    if (@RemovedOptions) {
                        if ($Multiple) {
                            for my $RemovedOption (@RemovedOptions) {
                                push @{ $GetParam{$Key} }, $RemovedOption;
                            }
                        }
                        else {
                            $GetParam{$Key} = shift @RemovedOptions;
                        }
                    }
                }

                # ticket params
                %ArticleParam = (
                    %ArticleParam,
                    $Object->ArticleOption( %GetParam, %ArticleParam, Config => $Jobs{$Job} ),
                );

                # get errors
                %Error = (
                    %Error,
                    $Object->Error( %GetParam, Config => $Jobs{$Job} ),
                );
            }
        }

        # Make sure we don't save form if a draft was loaded.
        if ( $Self->{LoadedFormDraftID} ) {
            %Error = ( LoadedFormDraft => 1 );
        }

        # check errors
        if (%Error) {

            my $Output = $LayoutObject->Header(
                Value     => $Ticket{TicketNumber},
                Type      => 'Small',
                BodyClass => 'Popup',
            );

            # When a draft is loaded, inform a user that article subject will be empty
            # if contains only the ticket hook (if nothing is modified).
            if ( $Error{LoadedFormDraft} ) {
                $Output .= $LayoutObject->Notify(
                    Data => $LayoutObject->{LanguageObject}->Translate(
                        'Article subject will be empty if the subject contains only the ticket hook!'
                    ),
                );
            }

            $GetParam{StandardResponse} = $GetParam{Body};
            $Output .= $Self->_Mask(
                TicketID   => $Self->{TicketID},
                NextStates => $Self->_GetNextStates(
                    %GetParam,
                ),
                ResponseFormat      => $LayoutObject->Ascii2Html( Text => $GetParam{Body} ),
                Errors              => \%Error,
                Attachments         => \@Attachments,
                GetParam            => \%GetParam,
                TicketBackType      => $TicketBackType,
                %Ticket,
                %GetParam,
            );
            $Output .= $LayoutObject->Footer(
                Type => 'Small',
            );
            return $Output;
        }

        # replace <OTOBO_TICKET_STATE> with next ticket state name
        if ( $StateData{Name} ) {
            $GetParam{Body} =~ s/<OTOBO_TICKET_STATE>/$StateData{Name}/g;
            $GetParam{Body} =~ s/&lt;OTOBO_TICKET_STATE&gt;/$StateData{Name}/g;
        }

        # get pre loaded attachments
        my @AttachmentData = $UploadCacheObject->FormIDGetAllFilesData(
            FormID => $Self->{FormID},
        );

        # get submit attachment
        my %UploadStuff = $ParamObject->GetUploadAll(
            Param => 'FileUpload',
        );
        if (%UploadStuff) {
            push @AttachmentData, \%UploadStuff;
        }

        # get recipients
        my $Recipients = '';
        LINE:
        my $MimeType = 'text/plain';
        if ( $LayoutObject->{BrowserRichText} ) {
            $MimeType = 'text/html';

            # remove unused inline images
            my @NewAttachmentData;
            ATTACHMENT:
            for my $Attachment (@AttachmentData) {
                my $ContentID = $Attachment->{ContentID};
                if ( $ContentID && ( $Attachment->{ContentType} =~ /image/i ) ) {
                    my $ContentIDHTMLQuote = $LayoutObject->Ascii2Html(
                        Text => $ContentID,
                    );

                    # workaround for link encode of rich text editor, see bug#5053
                    my $ContentIDLinkEncode = $LayoutObject->LinkEncode($ContentID);
                    $GetParam{Body} =~ s/(ContentID=)$ContentIDLinkEncode/$1$ContentID/g;

                    # IF the image is referenced in the body set it as inline.
                    if ( $GetParam{Body} =~ /(\Q$ContentIDHTMLQuote\E|\Q$ContentID\E)/i ) {
                        $Attachment->{Disposition} = 'inline';
                    }
                    elsif ( $Attachment->{Disposition} eq 'inline' ) {

                        # Ignore attachment if not linked in body.
                        next ATTACHMENT;
                    }
                }

                # remember inline images and normal attachments
                push @NewAttachmentData, \%{$Attachment};
            }
            @AttachmentData = @NewAttachmentData;

            # verify HTML document
            $GetParam{Body} = $LayoutObject->RichTextDocumentComplete(
                String => $GetParam{Body},
            );
        }

        # Get attributes like sender address
        my %Data = $Kernel::OM->Get('Kernel::System::TemplateGenerator')->Attributes(
            TicketID => $Self->{TicketID},
            Data     => {},
            UserID   => $Self->{UserID},
        );

        # send email
        my $ArticleID = $ArticleBackendObject->ArticleSend(
            SenderType           => 'agent',
            TicketID             => $Self->{TicketID},
            HistoryType          => 'SendAnswer',
            HistoryComment       => "\%\%$Recipients",
            From                 => $Data{From},
            To                   => $GetParam{To},
            Cc                   => $GetParam{Cc},
            Bcc                  => $GetParam{Bcc},
            Subject              => $GetParam{Subject},
            UserID               => $Self->{UserID},
            Body                 => $GetParam{Body},
            InReplyTo            => $GetParam{InReplyTo},
            References           => $GetParam{References},
            Charset              => $LayoutObject->{UserCharset},
            MimeType             => $MimeType,
            Attachment           => \@AttachmentData,
            %ArticleParam,
        );

        # error page
        if ( !$ArticleID ) {
            return $LayoutObject->ErrorScreen();
        }

        # time accounting
        if ( $GetParam{TimeUnits} ) {
            $TicketObject->TicketAccountTime(
                TicketID  => $Self->{TicketID},
                ArticleID => $ArticleID,
                TimeUnit  => $GetParam{TimeUnits},
                UserID    => $Self->{UserID},
            );
        }

        # set state
        $TicketObject->TicketStateSet(
            TicketID  => $Self->{TicketID},
            ArticleID => $ArticleID,
            StateID   => $GetParam{StateID},
            UserID    => $Self->{UserID},
        );

        # should I set an unlock?
        if ( $StateData{TypeName} =~ /^close/i ) {
            $TicketObject->TicketLockSet(
                TicketID => $Self->{TicketID},
                Lock     => 'unlock',
                UserID   => $Self->{UserID},
            );
        }

        # set pending time
        elsif ( $StateData{TypeName} =~ /^pending/i ) {
            $TicketObject->TicketPendingTimeSet(
                UserID   => $Self->{UserID},
                TicketID => $Self->{TicketID},
                Year     => $GetParam{Year},
                Month    => $GetParam{Month},
                Day      => $GetParam{Day},
                Hour     => $GetParam{Hour},
                Minute   => $GetParam{Minute},
            );
        }

        # log use response id and reply article id (useful for response diagnostics)
        $TicketObject->HistoryAdd(
            Name         => "ResponseTemplate ($GetParam{ResponseID}/$GetParam{ReplyArticleID}/$ArticleID)",
            HistoryType  => 'Misc',
            TicketID     => $Self->{TicketID},
            CreateUserID => $Self->{UserID},
        );

        # remove all form data
        $Kernel::OM->Get('Kernel::System::Web::FormCache')->FormIDRemove( FormID => $Self->{FormID} );

        # If form was called based on a draft,
        #   delete draft since its content has now been used.
        if (
            $GetParam{FormDraftID}
            && !$Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftDelete(
                FormDraftID => $GetParam{FormDraftID},
                UserID      => $Self->{UserID},
            )
            )
        {
            return $LayoutObject->ErrorScreen(
                Message => Translatable('Could not delete draft!'),
                Comment => Translatable('Please contact the administrator.'),
            );
        }

        # load new URL in parent window and close popup
        if (
            $StateData{TypeName} =~ /^close/i
            && !$ConfigObject->Get('Ticket::Frontend::RedirectAfterCloseDisabled')
            )
        {
            return $LayoutObject->PopupClose(
                URL => ( $Self->{LastScreenOverview} || 'Action=AgentDashboard' ),
            );
        }

        return $LayoutObject->PopupClose(
            URL => "Action=AgentTicketZoom;TicketID=$Self->{TicketID};ArticleID=$ArticleID",
        );
    }

    # check for SMIME / PGP if customer has changed
    elsif ( $Self->{Subaction} eq 'AJAXUpdate' ) {

        my @ExtendedData;

        # run compose modules
        if ( ref $ConfigObject->Get('Ticket::Frontend::ArticleComposeModule') eq 'HASH' ) {

            # use ticket QueueID in compose modules
            $GetParam{QueueID} = $Ticket{QueueID};

            my %Jobs = %{ $ConfigObject->Get('Ticket::Frontend::ArticleComposeModule') };
            JOB:
            for my $Job ( sort keys %Jobs ) {

                # load module
                next JOB if !$MainObject->Require( $Jobs{$Job}->{Module} );

                my $Object = $Jobs{$Job}->{Module}->new(
                    %{$Self},
                    Debug => $Self->{Debug},
                );

                my $Multiple;

                # get params
                PARAMETER:
                for my $Parameter ( $Object->Option( %GetParam, Config => $Jobs{$Job} ) ) {
                    if ( $Jobs{$Job}->{ParamType} && $Jobs{$Job}->{ParamType} ne 'Single' ) {
                        @{ $GetParam{$Parameter} } = $ParamObject->GetArray( Param => $Parameter );
                        $Multiple = 1;
                        next PARAMETER;
                    }

                    $GetParam{$Parameter} = $ParamObject->GetParam( Param => $Parameter );
                }

                # run module
                my %Data = $Object->Data( %GetParam, Config => $Jobs{$Job} );

                # get AJAX param values
                if ( $Object->can('GetParamAJAX') ) {
                    %GetParam = ( %GetParam, $Object->GetParamAJAX(%GetParam) );
                }

                # get options that have to be removed from the selection visible
                # to the agent. These options will be added again on submit.
                if ( $Object->can('GetOptionsToRemoveAJAX') ) {
                    my @OptionsToRemove = $Object->GetOptionsToRemoveAJAX(%GetParam);

                    for my $OptionToRemove (@OptionsToRemove) {
                        delete $Data{$OptionToRemove};
                    }
                }

                my $Key = $Object->Option( %GetParam, Config => $Jobs{$Job} );
                if ($Key) {
                    push @ExtendedData, {
                        Name         => $Key,
                        Data         => \%Data,
                        SelectedID   => $GetParam{$Key},
                        Translation  => 1,
                        PossibleNone => 1,
                        Multiple     => $Multiple,
                        Max          => 150,
                    };
                }
            }
        }

        my $NextStates = $Self->_GetNextStates(
            %GetParam,
        );

        my $JSON = $LayoutObject->BuildSelectionJSON(
            [
                @ExtendedData,
                {
                    Name         => 'StateID',
                    Data         => $NextStates,
                    SelectedID   => $GetParam{StateID},
                    Translation  => 1,
                    PossibleNone => 1,
                    Max          => 100,
                },
            ],
        );

        # can't use JSONReply here, as we already have JSON
        return $LayoutObject->Attachment(
            ContentType => 'application/json',
            Content     => $JSON,
            Type        => 'inline',
            NoCache     => 1,
        );
    }
    else {
        my $Output = $LayoutObject->Header(
            Value     => $Ticket{TicketNumber},
            Type      => 'Small',
            BodyClass => 'Popup',
        );

        # get std attachment object
        my $StdAttachmentObject = $Kernel::OM->Get('Kernel::System::StdAttachment');

        # handle response template attachments and state
        if ( $GetParam{ResponseID} ) {

            # add std. attachments to email
            my %AllStdAttachments = $StdAttachmentObject->StdAttachmentStandardTemplateMemberList(
                StandardTemplateID => $GetParam{ResponseID},
            );
            for ( sort keys %AllStdAttachments ) {
                my %Data = $StdAttachmentObject->StdAttachmentGet( ID => $_ );
                $UploadCacheObject->FormIDAddFile(
                    FormID      => $Self->{FormID},
                    Disposition => 'attachment',
                    %Data,
                );
            }

            # set response preselected state
            my %Response = $Kernel::OM->Get('Kernel::System::ResponseTemplatesStatePreselection')->StandardTemplateGet(
                ID => $GetParam{ResponseID},
            );
            $GetParam{StateID} ||= $Response{PreSelectedTicketStateID};
        }

        # get all attachments meta data
        my @Attachments = $UploadCacheObject->FormIDGetAllFilesMeta(
            FormID => $Self->{FormID},
        );

        # get last customer article or selected article
        my @ArticleList;

        if ( $GetParam{ArticleID} ) {

            @ArticleList = $ArticleObject->ArticleList(
                TicketID  => $Self->{TicketID},
                ArticleID => $GetParam{ArticleID},
            );
        }
        else {

            @ArticleList = $ArticleObject->ArticleList(
                TicketID             => $Self->{TicketID},
                IsVisibleForCustomer => 1,
                OnlyLast             => 1,
            );
        }

        my %Data;

        ARTICLEMETADATA:
        for my $ArticleMetaData (@ArticleList) {

            next ARTICLEMETADATA if !$ArticleMetaData;
            next ARTICLEMETADATA if !IsHashRefWithData($ArticleMetaData);

            my $CurrentArticleBackendObject = $ArticleObject->BackendForArticle( %{$ArticleMetaData} );

            %Data = $CurrentArticleBackendObject->ArticleGet(
                TicketID  => $Self->{TicketID},
                ArticleID => $ArticleMetaData->{ArticleID},
            );

            $Data{CommunicationChannelName} = $CurrentArticleBackendObject->ChannelNameGet();

            last ARTICLEMETADATA;
        }

        # Merge ticket data with article data, see bug#13995 (https://bugs.otrs.org/show_bug.cgi?id=13995).
        %Data = ( %Ticket, %Data );

        # If article is not a MIMEBase article, get customer recipients from the backend.
        if ( !$Data{To} && !$Data{From} ) {
            my @CustomerUserIDs = $LayoutObject->ArticleCustomerRecipientsGet(
                TicketID  => $Self->{TicketID},
                ArticleID => $Data{ArticleID},
                UserID    => $Self->{UserID},
            );

            my $CustomerUserObject = $Kernel::OM->Get('Kernel::System::CustomerUser');

            my @CustomerRecipients;

            CUSTOMER_USER_ID:
            for my $CustomerUserID (@CustomerUserIDs) {
                my %Customer = $CustomerUserObject->CustomerUserDataGet(
                    User => $CustomerUserID,
                );
                next CUSTOMER_USER_ID if !%Customer;

                push @CustomerRecipients, "\"$Customer{UserFirstname} $Customer{UserLastname}\" <$Customer{UserEmail}>";
            }

            $Data{To} = join( ',', @CustomerRecipients ) // '';

            # Include sender name in 'From' field for correct quoting.
            my %ArticleFields = $LayoutObject->ArticleFields(
                TicketID  => $Self->{TicketID},
                ArticleID => $Data{ArticleID},
            );
            $Data{From} = $ArticleFields{Sender}->{Value} // '';
        }

        # set OrigFrom for correct email quoting (xxxx wrote)
        $Data{OrigFrom} = $Data{From};

        # check article type and replace To with From (in case)
        if ( $Data{SenderType} !~ /customer/ ) {

            # replace From/To, To/From because sender is agent
            my $To = $Data{To};
            $Data{To}   = $Data{From};
            $Data{From} = $To;

            $Data{ReplyTo} = '';
        }

        # build OrigFromName (to only use the realname)
        $Data{OrigFromName} = $Data{OrigFrom};
        $Data{OrigFromName} =~ s/<.*>|\(.*\)|\"|;|,//g;
        $Data{OrigFromName} =~ s/( $)|(  $)//g;

        # Fallback to OrigFrom if realname part is empty.
        if ( !$Data{OrigFromName} ) {
            $Data{OrigFromName} = $Data{OrigFrom};
        }

        # get customer data
        my %Customer;
        if ( $Ticket{CustomerUserID} ) {
            %Customer = $Kernel::OM->Get('Kernel::System::CustomerUser')->CustomerUserDataGet(
                User => $Ticket{CustomerUserID}
            );
        }

        # get article to quote
        $Data{Body} = $LayoutObject->ArticleQuote(
            TicketID          => $Self->{TicketID},
            ArticleID         => $Data{ArticleID},
            FormID            => $Self->{FormID},
            UploadCacheObject => $UploadCacheObject,
        );

        my %SafetyCheckResult = $Kernel::OM->Get('Kernel::System::HTMLUtils')->Safety(
            String => $Data{Body},

            # Strip out external content if BlockLoadingRemoteContent is enabled.
            NoExtSrcLoad => $ConfigObject->Get('Ticket::Frontend::BlockLoadingRemoteContent'),

            # Disallow potentially unsafe content.
            NoApplet     => 1,
            NoObject     => 1,
            NoEmbed      => 1,
            NoSVG        => 1,
            NoJavaScript => 1,
        );
        $Data{Body} = $SafetyCheckResult{String};

        # restrict number of body lines if configured
        if (
            $Data{Body}
            && $ConfigObject->Get('Ticket::Frontend::ResponseQuoteMaxLines')
            )
        {
            my $MaxLines = $ConfigObject->Get('Ticket::Frontend::ResponseQuoteMaxLines');

            # split body - one element per line
            my @Body = split /\n/, $Data{Body};

            # only modify if body is longer than allowed
            if ( scalar @Body > $MaxLines ) {

                # splice to max. allowed lines and reassemble
                @Body       = @Body[ 0 .. ( $MaxLines - 1 ) ];
                $Data{Body} = join "\n", @Body;
            }
        }

        if ( $LayoutObject->{BrowserRichText} ) {

            # prepare body, subject, ReplyTo
            # rewrap body if exists
            if ( $Data{Body} ) {
                $Data{Body} =~ s/\t/ /g;
                my $Quote = $LayoutObject->Ascii2Html(
                    Text           => $ConfigObject->Get('Ticket::Frontend::Quote') || '',
                    HTMLResultMode => 1,
                );
                if ($Quote) {

                    # quote text
                    $Data{Body} = "<blockquote type=\"cite\">$Data{Body}</blockquote>\n";

                    # cleanup not compat. tags
                    $Data{Body} = $LayoutObject->RichTextDocumentCleanup(
                        String => $Data{Body},
                    );

                }
                else {
                    $Data{Body} = "<br/>" . $Data{Body};

                    if ( $Data{CreateTime} ) {
                        $Data{Body} = $LayoutObject->{LanguageObject}->Translate('Date') .
                            ": $Data{CreateTime}<br/>" . $Data{Body};
                    }

                    for (qw(Subject ReplyTo Reply-To Cc To From)) {
                        if ( $Data{$_} ) {
                            $Data{Body} = $LayoutObject->{LanguageObject}->Translate($_) .
                                ": $Data{$_}<br/>" . $Data{Body};
                        }
                    }

                    my $From = $LayoutObject->Ascii2RichText(
                        String => $Data{From},
                    );

                    my $MessageFrom = $LayoutObject->{LanguageObject}->Translate('Message from');
                    my $EndMessage  = $LayoutObject->{LanguageObject}->Translate('End message');

                    $Data{Body} = "<br/>---- $MessageFrom $From ---<br/><br/>" . $Data{Body};
                    $Data{Body} .= "<br/>---- $EndMessage ---<br/>";
                }
            }
        }
        else {

            # prepare body, subject, ReplyTo
            # re-wrap body if exists
            if ( $Data{Body} ) {
                $Data{Body} =~ s/\t/ /g;
                my $Quote = $ConfigObject->Get('Ticket::Frontend::Quote');
                if ($Quote) {
                    $Data{Body} =~ s/\n/\n$Quote /g;
                    $Data{Body} = "\n$Quote " . $Data{Body};
                }
                else {
                    $Data{Body} = "\n" . $Data{Body};
                    if ( $Data{CreateTime} ) {
                        $Data{Body} = $LayoutObject->{LanguageObject}->Translate('Date') .
                            ": $Data{CreateTime}\n" . $Data{Body};
                    }

                    for (qw(Subject ReplyTo Reply-To Cc To From)) {
                        if ( $Data{$_} ) {
                            $Data{Body} = $LayoutObject->{LanguageObject}->Translate($_) .
                                ": $Data{$_}\n" . $Data{Body};
                        }
                    }

                    my $MessageFrom = $LayoutObject->{LanguageObject}->Translate('Message from');
                    my $EndMessage  = $LayoutObject->{LanguageObject}->Translate('End message');

                    $Data{Body} = "\n---- $MessageFrom $Data{From} ---\n\n" . $Data{Body};
                    $Data{Body} .= "\n---- $EndMessage ---\n";
                }
            }
        }

        # get template
        my $TemplateGenerator = $Kernel::OM->Get('Kernel::System::TemplateGenerator');

        # use key StdResponse to pass the data to the template for legacy reasons,
        #   because existing systems may have it in their configuration as that was
        #   the key used before the internal switch to StandardResponse And StandardTemplate

        $Data{StdResponse} = $TemplateGenerator->Template(
            TicketID   => $Self->{TicketID},
            ArticleID  => $GetParam{ArticleID},
            TemplateID => $GetParam{ResponseID},
            Data       => \%Data,
            UserID     => $Self->{UserID},
        );

        # get salutation
        $Data{Salutation} = $TemplateGenerator->Salutation(
            TicketID => $Self->{TicketID},
            Data     => \%Data,
            UserID   => $Self->{UserID},
        );

        # get signature
        $Data{Signature} = $TemplateGenerator->Signature(
            TicketID => $Self->{TicketID},
            Data     => \%Data,
            UserID   => $Self->{UserID},
        );

        # $TemplateGenerator->Attributes() does not overwrite %Data, but it adds more keys
        %Data = $TemplateGenerator->Attributes(
            TicketID  => $Self->{TicketID},
            ArticleID => $GetParam{ArticleID},
            Data      => \%Data,
            UserID    => $Self->{UserID},
        );

        my $ResponseFormat = $ConfigObject->Get('Ticket::Frontend::ResponseFormat');

        # make sure body is rich text
        my %DataHTML = %Data;
        if ( $LayoutObject->{BrowserRichText} ) {
            if ($ResponseFormat) {
                $ResponseFormat = $LayoutObject->Ascii2RichText(
                    String => $ResponseFormat,
                );

                # restore qdata formatting for Output replacement
                $ResponseFormat =~ s/&quot;/"/gi;

                # html quote to have it correct in edit area
                $ResponseFormat = $LayoutObject->Ascii2Html(
                    Text => $ResponseFormat,
                );

                # restore qdata formatting for Output replacement
                $ResponseFormat =~ s/&quot;/"/gi;
            }

            # quote all non html content to have it correct in edit area
            KEY:
            for my $Key ( sort keys %DataHTML ) {
                next KEY if !$DataHTML{$Key};
                next KEY if $Key eq 'Salutation';
                next KEY if $Key eq 'Body';
                next KEY if $Key eq 'StdResponse';
                next KEY if $Key eq 'Signature';
                $DataHTML{$Key} = $LayoutObject->Ascii2RichText(
                    String => $DataHTML{$Key},
                );
            }
        }

        # build new response format based on template
        $Data{ResponseFormat} = $LayoutObject->Output(
            Template => $ResponseFormat,
            Data     => { %Param, %DataHTML },
        );

        # build references if exist
        my $References = ( $Data{MessageID} || '' ) . ( $Data{References} || '' );

        # run compose modules
        if ( ref $ConfigObject->Get('Ticket::Frontend::ArticleComposeModule') eq 'HASH' ) {

            # use ticket QueueID in compose modules
            $GetParam{QueueID} = $Ticket{QueueID};

            my %Jobs = %{ $ConfigObject->Get('Ticket::Frontend::ArticleComposeModule') };
            for my $Job ( sort keys %Jobs ) {

                # load module
                if ( !$MainObject->Require( $Jobs{$Job}->{Module} ) ) {
                    return $LayoutObject->FatalError();
                }
                my $Object = $Jobs{$Job}->{Module}->new( %{$Self}, Debug => $Self->{Debug} );

                # get params
                PARAMETER:
                for my $Parameter ( $Object->Option( %GetParam, Config => $Jobs{$Job} ) ) {
                    if ( $Jobs{$Job}->{ParamType} && $Jobs{$Job}->{ParamType} ne 'Single' ) {
                        @{ $GetParam{$Parameter} } = $ParamObject->GetArray( Param => $Parameter );
                        next PARAMETER;
                    }

                    $GetParam{$Parameter} = $ParamObject->GetParam( Param => $Parameter );
                }

                # run module
                my $NewParams = $Object->Run( %GetParam, Config => $Jobs{$Job} );

                if ($NewParams) {
                    for my $Parameter ( $Object->Option( %GetParam, Config => $Jobs{$Job} ) ) {
                        $GetParam{$Parameter} = $NewParams;
                    }
                }
            }
        }

        # build view
        $Output .= $Self->_Mask(
            TicketID   => $Self->{TicketID},
            NextStates => $Self->_GetNextStates(
                %GetParam,
            ),
            Attachments         => \@Attachments,
            GetParam            => \%GetParam,
            ResponseID          => $GetParam{ResponseID},
            ReplyArticleID      => $GetParam{ArticleID},
            %Ticket,
            %Data,
            InReplyTo        => $Data{MessageID},
            References       => "$References",
            TicketBackType   => $TicketBackType,
        );
        $Output .= $LayoutObject->Footer(
            Type => 'Small',
        );
        return $Output;
    }
}

sub _GetNextStates {
    my ( $Self, %Param ) = @_;

    # get next states
    my %NextStates = $Kernel::OM->Get('Kernel::System::Ticket')->TicketStateList(
        %Param,
        Action   => $Self->{Action},
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );
    return \%NextStates;
}

sub _Mask {
    my ( $Self, %Param ) = @_;

    # get needed objects
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get config for frontend module
    my $Config = $ConfigObject->Get("Ticket::Frontend::$Self->{Action}");
    my $CustomerUserObject = $Kernel::OM->Get('Kernel::System::CustomerUser');

    $LayoutObject->Block(
        Name => $Param{TicketBackType},
        Data => {

            #            FormID => $Self->{FormID},
            %Param,
        },
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
    if ( $Self->{LoadedFormDraftID} ) {
        $LoadedFormDraft = $Kernel::OM->Get('Kernel::System::FormDraft')->FormDraftGet(
            FormDraftID => $Self->{LoadedFormDraftID},
            GetContent  => 0,
            ObjectID    => $Self->{TicketID},
            UserID      => $Self->{UserID},
        );

        my @Articles = $Kernel::OM->Get('Kernel::System::Ticket::Article')->ArticleList(
            TicketID => $Self->{TicketID},
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
    }

    if ( IsHashRefWithData($LoadedFormDraft) ) {

        $LoadedFormDraft->{ChangeByName} = $Kernel::OM->Get('Kernel::System::User')->UserName(
            UserID => $LoadedFormDraft->{ChangeBy},
        );
    }

    # explanatory message about asterisk
    if ( $ConfigObject->Get('Ticket::Frontend::AsteriskExplanation') ) {
        $LayoutObject->Block(
            Name => 'AsteriskExplanation',
        );
    }

    if ( $Self->{AccessMode} ne "rw" ) {
        $Param{ReadOnly}      = 'readonly';
        $Param{ReadOnlyClass} = 'Readonly';
    }

    $LayoutObject->Block(
        Name => 'ToCustomer',
        Data => {
            ToCustomer => $Param{GetParam}{To}
        }
    );
    $LayoutObject->Block(
        Name => 'CcCustomer',
        Data => {
            Cc => $Param{GetParam}{Cc}
        }
    );
    $LayoutObject->Block(
        Name => 'BccCustomer',
        Data => {
            Bcc => $Param{GetParam}{Bcc}
        }
    );

    # create & return output
    return $LayoutObject->Output(
        TemplateFile => 'AgentTicketFormDraftEdit',
        Data         => {
            FormID         => $Self->{FormID},
            FormDraft      => $Config->{FormDraft},
            FormDraftID    => $Self->{LoadedFormDraftID},
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
        Action      => $MetaParams{Action},
        Title       => $MetaParams{FormDraftTitle},
        UserID      => $Param{UserID},
    );

    # update draft
    if ( $MetaParams{FormDraftID} ) {
        return unless $DraftFormObject->FormDraftUpdate(%FormDraft);
        return 1;
    }

    # create new draft
    return unless $DraftFormObject->FormDraftAdd(%FormDraft);
    return 1;
}

1;

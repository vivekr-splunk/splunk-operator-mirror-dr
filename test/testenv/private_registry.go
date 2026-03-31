package testenv

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const defaultPrivateRegistryPullSecretName = "private-registry-credentials"

type dockerConfigEntry struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Auth     string `json:"auth"`
}

type dockerConfigFile struct {
	Auths map[string]dockerConfigEntry `json:"auths"`
}

func privateRegistryPullSecretConfig() (string, string, string, string, bool) {
	if privateRegistryAuthMode() != "secret" {
		return "", "", "", "", false
	}

	secretName := os.Getenv("PRIVATE_REGISTRY_SECRET_NAME")
	if secretName == "" {
		secretName = defaultPrivateRegistryPullSecretName
	}

	server := os.Getenv("PRIVATE_REGISTRY_SERVER")
	username := os.Getenv("PRIVATE_REGISTRY_USERNAME")
	password := os.Getenv("PRIVATE_REGISTRY_PASSWORD")
	if server == "" || username == "" || password == "" {
		return "", "", "", "", false
	}

	return secretName, server, username, password, true
}

func privateRegistryAuthMode() string {
	mode := os.Getenv("PRIVATE_REGISTRY_AUTH_MODE")
	switch mode {
	case "node", "secret":
		return mode
	}

	server := os.Getenv("PRIVATE_REGISTRY_SERVER")
	username := os.Getenv("PRIVATE_REGISTRY_USERNAME")
	password := os.Getenv("PRIVATE_REGISTRY_PASSWORD")
	if server != "" && username != "" && password != "" {
		return "secret"
	}

	return "node"
}

func privateRegistryPullSecretRefs() []corev1.LocalObjectReference {
	secretName, _, _, _, ok := privateRegistryPullSecretConfig()
	if !ok {
		return nil
	}

	return []corev1.LocalObjectReference{{Name: secretName}}
}

func ensurePrivateRegistryPullSecret(ctx context.Context, kubeClient client.Client, namespace string) (string, error) {
	secretName, server, username, password, ok := privateRegistryPullSecretConfig()
	if !ok {
		return "", nil
	}

	auth := base64.StdEncoding.EncodeToString([]byte(username + ":" + password))
	configJSON, err := json.Marshal(dockerConfigFile{
		Auths: map[string]dockerConfigEntry{
			server: {
				Username: username,
				Password: password,
				Auth:     auth,
			},
		},
	})
	if err != nil {
		return "", err
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: namespace,
		},
		Data: map[string][]byte{
			corev1.DockerConfigJsonKey: configJSON,
		},
		Type: corev1.SecretTypeDockerConfigJson,
	}

	err = kubeClient.Create(ctx, secret)
	if err != nil {
		if !errors.IsAlreadyExists(err) {
			return "", err
		}

		current := &corev1.Secret{}
		key := client.ObjectKey{Name: secretName, Namespace: namespace}
		if getErr := kubeClient.Get(ctx, key, current); getErr != nil {
			return "", getErr
		}
		current.Data = secret.Data
		current.Type = corev1.SecretTypeDockerConfigJson
		if updateErr := kubeClient.Update(ctx, current); updateErr != nil {
			return "", updateErr
		}
	}

	return secretName, nil
}
